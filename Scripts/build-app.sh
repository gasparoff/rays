#!/bin/bash
# Builds a release "RAYS.app" into dist/ with SwiftPM only, then signs it ad hoc.
# No network access, no system configuration changes, no external build tooling.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="RAYS"
BUNDLE_ID="io.github.gasparoff.rays"
VERSION="1.5.5"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
DIST="${LIGHT_SYSTEM_DIST:-$ROOT/dist}"
APP="$DIST/$APP_NAME.app"

if [ ! -f "Vendor/link/include/ableton/Link.hpp" ] || [ ! -f "Vendor/link/modules/asio-standalone/asio/include/asio.hpp" ]; then
  echo "Errore: manca l'SDK Ableton Link in Vendor/link (con il sottomodulo asio-standalone)." >&2
  exit 1
fi

# Never remove a bundle whose executable is in use.
if /bin/ps -axo command= | /usr/bin/grep -Fqx "$APP/Contents/MacOS/LightSystem"; then
  echo "Errore: questa app è aperta. Chiudila, oppure imposta LIGHT_SYSTEM_DIST per creare una copia separata." >&2
  exit 1
fi

echo "==> Compilazione adattatore Beat Link"
"$ROOT/Scripts/build-beatlink-helper.sh"

echo "==> swift build -c release"
swift build -c release --product LightSystem
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "==> Assemblaggio bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Licenses" "$APP/Contents/Resources/Profiles" \
  "$APP/Contents/Resources/Controllers"
cp "$BIN_DIR/LightSystem" "$APP/Contents/MacOS/LightSystem"
# Community fixture profiles (Profiles/**/*.json, subfolders kept), loaded at startup next to the built-in ones.
/usr/bin/rsync -a --include='*/' --include='*.json' --exclude='*' "$ROOT/Profiles/" "$APP/Contents/Resources/Profiles/"
# Controller layouts (Controllers/*.json), same loading rules.
find "$ROOT/Controllers" -maxdepth 1 -name '*.json' -exec cp {} "$APP/Contents/Resources/Controllers/" \; 2>/dev/null || true

cp "Vendor/link/LICENSE.md" "$APP/Contents/Resources/Licenses/AbletonLink-LICENSE.md"
cp "Vendor/link/GNU-GPL-v2.0.md" "$APP/Contents/Resources/Licenses/GNU-GPL-v2.0.md"
cp "Vendor/link/modules/asio-standalone/asio/LICENSE_1_0.txt" "$APP/Contents/Resources/Licenses/ASIO-BSL-1.0.txt" 2>/dev/null \
  || cp "Vendor/link/modules/asio-standalone/LICENSE_1_0.txt" "$APP/Contents/Resources/Licenses/ASIO-BSL-1.0.txt" 2>/dev/null || true
cat > "$APP/Contents/Resources/Licenses/NOTICE.txt" <<'EOF'
RAYS include Ableton Link (Copyright 2016, Ableton AG), concesso in licenza
GNU General Public License v2 o successiva, e ASIO standalone (Boost Software License 1.0).

Questa build è destinata a uso privato locale. Distribuire l'app ad altri richiede di
rilasciare l'intero programma sotto GPL insieme al codice sorgente completo, oppure di
ottenere una licenza commerciale di Link da Ableton (link-devs@ableton.com).
EOF

# Self-contained headless Beat Link runtime. The user's installed BLT is untouched.
HELPER="Vendor/BeatLinkHelper"
if [ ! -x "$HELPER/Contents/MacOS/Beat Link Trigger" ]; then
  echo "Errore: manca Vendor/BeatLinkHelper, necessario per la scoperta automatica della console." >&2
  exit 1
fi
cp -R "$HELPER" "$APP/Contents/Resources/BeatLinkHelper"
# Source included for the tiny adapter; Clojure is used only by the build compiler.
cp "Sources/BeatLinkHelper/LightSystemBeatLink.java" "$APP/Contents/Resources/BeatLinkHelper/Contents/app/LightSystemBeatLink.java"
rm -f "$APP/Contents/Resources/BeatLinkHelper/Contents/app/lightsystem.clj"
cp -R "$HELPER/Licenses" "$APP/Contents/Resources/Licenses/BeatLink"
# The original launcher signature covers its old configuration; sign our private copy.
codesign --force --sign - --timestamp=none "$APP/Contents/Resources/BeatLinkHelper/Contents/MacOS/Beat Link Trigger"

# Original three-triangle icon, kept as-is (never regenerated over).
ICON_KEY=""
if [ -f "Assets/LightSystem.icns" ]; then
  cp "Assets/LightSystem.icns" "$APP/Contents/Resources/AppIcon.icns"
  ICON_KEY="<key>CFBundleIconFile</key><string>AppIcon</string>"
else
  echo "Avviso: Assets/LightSystem.icns mancante, app senza icona." >&2
fi

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>it</string>
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
  <string>RAYS usa la rete locale per trovare l'interfaccia luci ENTTEC ODE MK3 e inviarle i dati DMX via Art-Net, per rilevare la console Pro DJ Link e per sincronizzarsi a tempo con Ableton Live e altre app tramite Ableton Link.</string>
  <key>NSHumanReadableCopyright</key><string>Include Ableton Link © Ableton AG (GPLv2+). Uso privato.</string>
</dict>
</plist>
EOF
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> Firma ad hoc"
codesign --force --deep --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"

echo "Fatto: $APP"
