#!/usr/bin/env python3
"""Lists Japanese string literals in Sources/ that the String Catalog won't translate.

Run scripts/update-strings.sh first: it leaves the compiler's extraction results in
.build/l10n/stringsdata. A literal counts as covered when a key extracted on the same line has
the same text, with each interpolation matching a format specifier (%@, %lld, …). Matching by text
rather than column: for `cond ? "a" : "b"` the compiler reports both keys at one location. Uncovered literals usually need String(localized:) (a String built
in code) or a localizable SwiftUI initializer (e.g. LabeledContent's value: takes a plain String).
Skipped: enum raw values (`case x = "…"`, used here only as identifiers; show a localized
`title` instead) and `defaultValue:` arguments (the key is the other argument).
"""
import glob, json, os, re, sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
os.chdir(ROOT)
keys_by_line = {}
for f in glob.glob(".build/l10n/stringsdata/*.stringsdata"):
    d = json.load(open(f))
    for entries in d["tables"].values():
        for e in entries:
            keys_by_line.setdefault((os.path.realpath(d["source"]), e["location"]["startingLine"]), set()).add(e["key"])

jp = re.compile(r"[぀-ヿ㐀-鿿＀-￯]")

def literals(line):
    """(column, text) of top-level string literals, 1-based columns."""
    i, out = 0, []
    while i < len(line):
        if line.startswith("//", i):
            break
        if line[i] == '"':
            j, depth = i + 1, 0
            while j < len(line):
                if line[j] == "\\" and line[j + 1:j + 2] == "(":
                    depth += 1; j += 2; continue
                if depth and line[j] == "(":
                    depth += 1; j += 1; continue
                if depth and line[j] == ")":
                    depth -= 1; j += 1; continue
                if depth and line[j] == '"':
                    j = line.index('"', j + 1) + 1; continue
                if line[j] == "\\":
                    j += 2; continue
                if line[j] == '"' and not depth:
                    break
                j += 1
            out.append((i + 1, line[i:j + 1]))
            i = j + 1
        else:
            i += 1
    return out

SPEC = r"%(?:\d+\$)?(?:@|lld|ld|d|lf|f|s)"

def pattern(text):
    """Regex for the key a literal produces: interpolations become any format specifier."""
    body = text[1:-1]
    out, i = "", 0
    while i < len(body):
        if body.startswith("\\(", i):
            depth, j = 1, i + 2
            # nested parentheses and string literals inside the interpolation
            while j < len(body) and depth:
                if body[j] == '"':
                    j = body.index('"', j + 1) + 1; continue
                depth += {"(": 1, ")": -1}.get(body[j], 0); j += 1
            out += SPEC; i = j; continue
        if body.startswith("\\n", i): out += "\n"; i += 2; continue
        if body.startswith("\\r", i): out += "\r"; i += 2; continue
        if body.startswith('\\"', i): out += '"'; i += 2; continue
        out += re.escape(body[i]); i += 1
    return re.compile(out.replace("%", "%%").replace("%%(?:", "%(?:") + "$") if False else re.compile(out + "$")

problems = 0
for f in sorted(glob.glob("Sources/**/*.swift", recursive=True)):
    for n, line in enumerate(open(f), 1):
        if line.lstrip().startswith("//"):
            continue
        for col, text in literals(line.rstrip("\n")):
            before = line[:col - 1]
            if re.search(r"\bcase\s+\w+\s*=\s*$", before) or before.rstrip().endswith("defaultValue:"):
                continue
            keys = keys_by_line.get((os.path.realpath(f), n), set())
            if jp.search(text) and not any(pattern(text).match(k) for k in keys):
                problems += 1
                print(f"{f}:{n}:{col}: {line.strip()[:120]}")
print(f"{problems} uncovered Japanese literal(s)", file=sys.stderr)
