#!/bin/bash
# Builds a release "RAYS.app" into dist/ with SwiftPM only, then signs it: ad hoc by default, or with a
# Developer ID and the hardened runtime when RAYS_SIGN_IDENTITY is set (release workflow, ready to notarize).
# No network access, no system configuration changes, no external build tooling.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="RAYS"
BUNDLE_ID="io.github.gasparoff.rays"
# Release builds pass RAYS_VERSION (e.g. from the git tag); local builds keep the last version.
VERSION="${RAYS_VERSION:-1.5.5}"
BUILD_NUMBER="${RAYS_BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
# Pro DJ Link needs the Beat Link helper (Scripts/bootstrap.sh). Without it the app is built
# anyway and Pro DJ Link is unavailable; set RAYS_REQUIRE_BEATLINK=1 to fail instead.
REQUIRE_BEATLINK="${RAYS_REQUIRE_BEATLINK:-0}"
# "Developer ID Application: Name (TEAMID)" from the keychain, or empty for an ad hoc signature.
SIGN_IDENTITY="${RAYS_SIGN_IDENTITY:-}"
HELPER_ENTITLEMENTS="$ROOT/Scripts/entitlements/beatlink-helper.entitlements"
HELPER="Vendor/BeatLinkHelper"
HAS_BEATLINK=0
if [ -x "$HELPER/Contents/MacOS/Beat Link Trigger" ]; then HAS_BEATLINK=1; fi
DIST="${LIGHT_SYSTEM_DIST:-$ROOT/dist}"
APP="$DIST/$APP_NAME.app"

if [ ! -f "Vendor/link/include/ableton/Link.hpp" ] || [ ! -f "Vendor/link/modules/asio-standalone/asio/include/asio.hpp" ]; then
  echo "Error: the Ableton Link SDK is missing from Vendor/link (with its asio-standalone submodule). Run make bootstrap." >&2
  exit 1
fi

# Never remove a bundle whose executable is in use.
if /bin/ps -axo command= | /usr/bin/grep -Fqx "$APP/Contents/MacOS/LightSystem"; then
  echo "Error: this app is running. Quit it, or set LIGHT_SYSTEM_DIST to build a separate copy." >&2
  exit 1
fi

if [ "$HAS_BEATLINK" = 1 ]; then
  echo "==> Beat Link adapter"
  "$ROOT/Scripts/build-beatlink-helper.sh"
elif [ "$REQUIRE_BEATLINK" = 1 ]; then
  echo "Error: Vendor/BeatLinkHelper is missing and RAYS_REQUIRE_BEATLINK=1. Run make bootstrap." >&2
  exit 1
else
  echo "Warning: Vendor/BeatLinkHelper is missing; building without Pro DJ Link (see Scripts/bootstrap.sh)." >&2
fi

echo "==> swift build -c release"
swift build -c release --product LightSystem
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "==> Assembling the bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Licenses" "$APP/Contents/Resources/Profiles" \
  "$APP/Contents/Resources/Controllers"
cp "$BIN_DIR/LightSystem" "$APP/Contents/MacOS/LightSystem"
# Community fixture profiles (Profiles/**/*.json, subfolders kept), loaded at startup next to the built-in ones.
/usr/bin/rsync -a --include='*/' --include='*.json' --exclude='*' "$ROOT/Profiles/" "$APP/Contents/Resources/Profiles/"
# Controller layouts (Controllers/*.json), same loading rules.
find "$ROOT/Controllers" -maxdepth 1 -name '*.json' -exec cp {} "$APP/Contents/Resources/Controllers/" \; 2>/dev/null || true

# Translations (English is the source language in code; see Localization/README.md).
for lproj in "$ROOT"/Localization/*.lproj; do
  cp -R "$lproj" "$APP/Contents/Resources/"
done

cp "Vendor/link/LICENSE.md" "$APP/Contents/Resources/Licenses/AbletonLink-LICENSE.md"
cp "Vendor/link/GNU-GPL-v2.0.md" "$APP/Contents/Resources/Licenses/GNU-GPL-v2.0.md"
cp "Vendor/link/modules/asio-standalone/asio/LICENSE_1_0.txt" "$APP/Contents/Resources/Licenses/ASIO-BSL-1.0.txt" 2>/dev/null \
  || cp "Vendor/link/modules/asio-standalone/LICENSE_1_0.txt" "$APP/Contents/Resources/Licenses/ASIO-BSL-1.0.txt" 2>/dev/null || true
cat > "$APP/Contents/Resources/Licenses/NOTICE.txt" <<'EOF'
RAYS source code is released under the MIT License:
https://github.com/gasparoff/rays

This application includes Ableton Link (Copyright 2016, Ableton AG), licensed under the
GNU General Public License v2 or later, and standalone ASIO (Boost Software License 1.0).
The application as a whole is therefore distributed under the GNU GPL v2 or later.
The complete corresponding source code is available at the address above.

When present, the Pro DJ Link helper runs Beat Link (Deep Symmetry, Eclipse Public
License 2.0) as a separate process; its licenses are in the BeatLink folder.
EOF

# Self-contained headless Beat Link runtime. The user's installed BLT is untouched.
if [ "$HAS_BEATLINK" = 1 ]; then
  # Only the bundle itself: anything else at its root (Licenses/) would break the code signature.
  mkdir -p "$APP/Contents/Resources/BeatLinkHelper"
  cp -R "$HELPER/Contents" "$APP/Contents/Resources/BeatLinkHelper/Contents"
  # Source included for the tiny adapter; Clojure is used only by the build compiler.
  cp "Sources/BeatLinkHelper/LightSystemBeatLink.java" "$APP/Contents/Resources/BeatLinkHelper/Contents/app/LightSystemBeatLink.java"
  rm -f "$APP/Contents/Resources/BeatLinkHelper/Contents/app/lightsystem.clj"
  cp -R "$HELPER/Licenses" "$APP/Contents/Resources/Licenses/BeatLink"
  # The original launcher signature covers its old configuration; sign our private copy.
  # With a Developer ID this happens below, together with the rest of the runtime.
  if [ -z "$SIGN_IDENTITY" ]; then
    codesign --force --sign - --timestamp=none "$APP/Contents/Resources/BeatLinkHelper/Contents/MacOS/Beat Link Trigger"
  fi
fi

# Original three-triangle icon, kept as-is (never regenerated over).
ICON_KEY=""
if [ -f "Assets/LightSystem.icns" ]; then
  cp "Assets/LightSystem.icns" "$APP/Contents/Resources/AppIcon.icns"
  ICON_KEY="<key>CFBundleIconFile</key><string>AppIcon</string>"
else
  echo "Warning: Assets/LightSystem.icns is missing; the app has no icon." >&2
fi

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>it</string></array>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>LightSystem</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  $ICON_KEY
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSSupportsSuddenTermination</key><false/>
  <key>NSLocalNetworkUsageDescription</key>
  <string>RAYS uses the local network to find your DMX interface and send it light data (Art-Net or sACN), to detect Pro DJ Link consoles and to stay in time with other apps through Ableton Link.</string>
  <key>NSHumanReadableCopyright</key><string>© Manuel Gasparini. MIT source; includes Ableton Link © Ableton AG (GPLv2+).</string>
</dict>
</plist>
EOF
plutil -lint "$APP/Contents/Info.plist" >/dev/null

if [ -z "$SIGN_IDENTITY" ]; then
  echo "==> Ad hoc signature"
  codesign --force --deep --sign - --timestamp=none "$APP"
  codesign --verify --strict "$APP"
else
  # Notarization needs every Mach-O signed with the Developer ID, a secure timestamp and the hardened
  # runtime, from the inside out (no --deep).
  echo "==> Developer ID signature"
  sign() { codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$@"; }
  HELPER_APP="$APP/Contents/Resources/BeatLinkHelper"
  if [ -d "$HELPER_APP" ]; then
    LAUNCHER="$HELPER_APP/Contents/MacOS/Beat Link Trigger"
    # Libraries and tools of the bundled Java runtime, deepest first.
    find "$HELPER_APP/Contents" -type f ! -path "$LAUNCHER" -print0 | sort -rz | while IFS= read -r -d '' f; do
      if file -b "$f" | grep -q 'Mach-O'; then
        sign --entitlements "$HELPER_ENTITLEMENTS" "$f"
      fi
    done
    if [ -d "$HELPER_APP/Contents/runtime" ]; then sign "$HELPER_APP/Contents/runtime"; fi
    sign --entitlements "$HELPER_ENTITLEMENTS" "$LAUNCHER"
  fi
  sign "$APP"
  codesign --verify --strict --deep --verbose=2 "$APP"
fi

echo "Done: $APP"
