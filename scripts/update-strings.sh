#!/bin/bash
# Updates Resources/Localizable.xcstrings from the source code.
#   scripts/update-strings.sh
#
# The app is built with SwiftPM, so nothing extracts strings automatically the way Xcode does.
# This compiles all modules with the Swift compiler's own extraction (-emit-localized-strings),
# which records the exact runtime keys (e.g. "「%@」を削除", "%lld 台"), then merges them into the
# catalog with xcstringstool. New keys appear without translations; stale ones are marked so.
# The source language is Japanese; add English in the catalog (Xcode can open the file too).
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
CATALOG="$ROOT/Resources/Localizable.xcstrings"
OUT="$ROOT/.build/l10n/stringsdata"

# Kept between runs: an up-to-date build doesn't recompile, so only changed files are re-extracted.
# Delete .build/l10n to start over.
mkdir -p "$OUT"
# A separate scratch path, so the extra flags don't invalidate the normal build.
swift build --scratch-path "$ROOT/.build/l10n/build" \
    -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$OUT" >/dev/null

if [[ ! -f "$CATALOG" ]]; then
    printf '{\n  "sourceLanguage" : "ja",\n  "strings" : {\n\n  },\n  "version" : "1.0"\n}\n' > "$CATALOG"
fi
# Only our own sources that still exist (dependencies are compiled with the same flags).
files=()
while IFS= read -r f; do
    src="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["source"])' "$f")"
    if [[ "$src" == "$ROOT/Sources/"* ]]; then
        if [[ -f "$src" ]]; then files+=("$f"); else rm -f "$f"; fi
    fi
done < <(find "$OUT" -name '*.stringsdata')
xcrun xcstringstool sync "$CATALOG" --stringsdata "${files[@]}"

# Give every key an explicit Japanese value, so ja.lproj is complete. The app's development
# region is English (the fallback for other languages), and a key missing from ja.lproj makes
# macOS look in the English tables, e.g. the English plural rules ("1 cores" in Japanese).
python3 - "$CATALOG" <<'PY'
import json, sys
path = sys.argv[1]
catalog = json.load(open(path))
for key, entry in catalog["strings"].items():
    locs = entry.setdefault("localizations", {})
    if "ja" not in locs:
        locs["ja"] = {"stringUnit": {"state": "translated", "value": key}}
json.dump(catalog, open(path, "w"), ensure_ascii=False, indent=2, sort_keys=True)
open(path, "a").write("\n")
PY
echo "✓ $(xcrun xcstringstool print "$CATALOG" | grep -c '^') keys in Resources/Localizable.xcstrings"
