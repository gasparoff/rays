#!/bin/bash
# Prepares third-party components that are not committed to the repository:
#   1. Ableton Link SDK (git submodule Vendor/link, with ASIO)
#   2. Beat Link helper runtime (copied from an installed Beat Link Trigger.app)
# Safe to run more than once. Never touches the installed Beat Link Trigger.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> Ableton Link (submodule)"
git submodule update --init --recursive Vendor/link
test -f Vendor/link/include/ableton/Link.hpp
test -f Vendor/link/modules/asio-standalone/asio/include/asio.hpp

echo "==> Beat Link helper"
HELPER="Vendor/BeatLinkHelper"
BLT="${BEAT_LINK_TRIGGER_APP:-/Applications/Beat Link Trigger.app}"
if [ -e "$HELPER" ]; then
  # Never overwrite an existing helper, even a partial one.
  echo "    already present in $HELPER (left untouched)"
elif [ -d "$BLT" ]; then
  mkdir -p "$HELPER/Licenses"
  cp -R "$BLT/Contents" "$HELPER/Contents"
  JAR="$HELPER/Contents/app/beat-link-trigger.jar"
  # Keep every license/notice shipped inside the jar next to the runtime.
  ( cd "$HELPER/Licenses" && /usr/bin/unzip -qo "$ROOT/$JAR" \
      'META-INF/*LICENSE*' 'META-INF/*NOTICE*' 'META-INF/leiningen/*/*/LICENSE*' 2>/dev/null || true )
  echo "Copied from $BLT (EPL-2.0, see THIRD_PARTY_NOTICES.md)." > "$HELPER/Licenses/PROVENANCE.txt"
  echo "    copied from $BLT"
else
  cat >&2 <<MSG
    Beat Link Trigger not found.
    Download it from https://github.com/Deep-Symmetry/beat-link-trigger/releases,
    install it in /Applications (or set BEAT_LINK_TRIGGER_APP), then run this script again.
    You can still run 'swift test' without it; only Scripts/build-app.sh needs it.
MSG
fi
echo "==> Done. Next: swift test && Scripts/build-app.sh"
