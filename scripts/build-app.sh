#!/bin/bash
# Builds HanaLima.app from the SwiftPM executable.
# Usage: scripts/build-app.sh [debug|release]   (default: debug)
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c "$CONFIG" --product HanaLima
swift build -c "$CONFIG" --product hanalima-netd
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP="$ROOT/build/HanaLima.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$BIN_DIR/HanaLima" "$APP/Contents/MacOS/HanaLima"
# Shown by the standard About panel.
cp "$ROOT/Resources/Credits.html" "$APP/Contents/Resources/Credits.html"

# SwiftPM resource bundles (e.g. from dependencies) are looked up next to the executable's bundle.
for bundle in "$BIN_DIR"/*.bundle; do
    [ -e "$bundle" ] || continue
    case "$(basename "$bundle")" in *Tests.bundle) continue ;; esac
    cp -R "$bundle" "$APP/Contents/Resources/"
done

# The network helper needs com.apple.security.virtualization for the vmnet_network APIs.
cp "$BIN_DIR/hanalima-netd" "$APP/Contents/Helpers/hanalima-netd"
codesign --force --sign - --entitlements "$ROOT/Resources/hanalima-netd.entitlements" \
    "$APP/Contents/Helpers/hanalima-netd" >/dev/null

# Ad-hoc signature so macOS runs it locally. Real signing/notarization comes with distribution.
# (Not --deep: that would re-sign the helper without its entitlements.)
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
