#!/bin/bash
# Compile the tiny adapter with the compiler module in the bundled Java runtime.
# The temporary compiler launcher is isolated from any running app/helper.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/Vendor/BeatLinkHelper"
COMPILER_DIR="$(mktemp -d "${TMPDIR:-/tmp/}light-system-javac.XXXXXX")"
trap 'rm -rf "$COMPILER_DIR"' EXIT
mkdir -p "$COMPILER_DIR/Contents/MacOS" "$COMPILER_DIR/Contents/app" "$HELPER/Contents/app/classes"
cp "$HELPER/Contents/MacOS/Beat Link Trigger" "$COMPILER_DIR/Contents/MacOS/Beat Link Trigger"
ln -s "$HELPER/Contents/runtime" "$COMPILER_DIR/Contents/runtime"
ln -s "$HELPER/Contents/app/beat-link-trigger.jar" "$COMPILER_DIR/Contents/app/beat-link-trigger.jar"
cat > "$COMPILER_DIR/Contents/app/Beat Link Trigger.cfg" <<'CFG'
[Application]
app.classpath=$APPDIR/beat-link-trigger.jar
app.mainclass=clojure.main
[JavaOptions]
java-options=-Djava.awt.headless=true
java-options=-Xms16m
java-options=-Xmx256m
CFG
codesign --force --sign - --timestamp=none "$COMPILER_DIR/Contents/MacOS/Beat Link Trigger" 2>/dev/null
"$COMPILER_DIR/Contents/MacOS/Beat Link Trigger" "$ROOT/Sources/BeatLinkHelper/compile.clj" "$ROOT/Sources/BeatLinkHelper/LightSystemBeatLink.java" "$HELPER/Contents/app/classes"

cp "$ROOT/Sources/BeatLinkHelper/LightSystemBeatLink.cfg" "$HELPER/Contents/app/Beat Link Trigger.cfg"
