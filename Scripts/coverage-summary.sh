#!/bin/sh
# Prints a per-module line-coverage table for the last `swift test --enable-code-coverage` run.
# Used by `make coverage` and by CI (which also appends it to $GITHUB_STEP_SUMMARY).
# Only Sources/ is counted: Tests/, Vendor/ and .build/ are excluded. macOS only (xcrun llvm-cov).
set -eu

codecov_dir=$(dirname "$(swift test --show-codecov-path)")
profdata="$codecov_dir/default.profdata"
bin_dir=$(swift build --show-bin-path)
bundle=$(find "$bin_dir" -maxdepth 1 -name '*PackageTests.xctest' | head -n 1)
if [ ! -f "$profdata" ] || [ -z "$bundle" ]; then
    echo "No coverage data: run 'swift test --enable-code-coverage' first." >&2
    exit 1
fi
binary="$bundle/Contents/MacOS/$(basename "$bundle" .xctest)"
ignore='(/\.build/|/Tests/|/Vendor/)'

json=$(mktemp)
trap 'rm -f "$json"' EXIT
xcrun llvm-cov export -summary-only -instr-profile="$profdata" -ignore-filename-regex="$ignore" "$binary" > "$json"

table=$(python3 - "$json" <<'PY'
import json, sys
from collections import defaultdict

with open(sys.argv[1]) as f:
    files = json.load(f)["data"][0]["files"]
modules = defaultdict(lambda: [0, 0])
for entry in files:
    path = entry["filename"]
    if "/Sources/" not in path:
        continue
    module = path.split("/Sources/", 1)[1].split("/", 1)[0]
    lines = entry["summary"]["lines"]
    modules[module][0] += lines["covered"]
    modules[module][1] += lines["count"]

def pct(covered, count):
    return f"{100 * covered / count:.1f}%" if count else "n/a"

print("| Module | Lines covered | Lines | Line coverage |")
print("|---|---:|---:|---:|")
for name in sorted(modules):
    covered, count = modules[name]
    print(f"| {name} | {covered} | {count} | {pct(covered, count)} |")
covered = sum(m[0] for m in modules.values())
count = sum(m[1] for m in modules.values())
print(f"| **Total** | {covered} | {count} | **{pct(covered, count)}** |")
PY
)

echo "$table"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
        echo "### Line coverage by module"
        echo
        echo "$table"
        echo
        echo "Sources only (Tests/, Vendor/ and .build/ excluded). The RaysApp executable is not linked into the test bundle, so it is not listed."
    } >> "$GITHUB_STEP_SUMMARY"
fi
