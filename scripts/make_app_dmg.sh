#!/bin/sh
# Builds dist/faceauth-app-<version>.dmg: faceauth.app plus an Applications
# shortcut. The app is a setup window; each button runs one step in Terminal.
# Usage (from the repository root):  sh scripts/make_app_dmg.sh [version]
set -eu
VERSION=${1:-0.1.0}
cd "$(dirname "$0")/.."

[ -d models/MobileFaceNet.mlpackage ] || { echo "Convert the model first: scripts/.venv/bin/python -I scripts/convert_model.py"; exit 1; }
swift build -c release
make -C pam pam_faceauth.so

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/dmg/faceauth.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/licenses"

cp .build/release/FaceAuthSetup "$APP/Contents/MacOS/FaceAuthSetup"
R="$APP/Contents/Resources"
cp .build/release/faceauth pam/pam_faceauth.so pam/install.sh pam/uninstall.sh README.md SPEC.md "$R/"
cp -R models/MobileFaceNet.mlpackage "$R/"
cp licenses/MobileFaceNet-LICENSE licenses/NOTICE.md "$R/licenses/"
chmod 755 "$R/faceauth" "$R/install.sh" "$R/uninstall.sh"

# Icon from the same glyph as the HUD.
.build/release/FaceAuthSetup --iconset "$WORK/AppIcon.iconset"
iconutil -c icns -o "$R/AppIcon.icns" "$WORK/AppIcon.iconset"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>FaceAuthSetup</string>
    <key>CFBundleIdentifier</key><string>dev.local.faceauth.setup</string>
    <key>CFBundleName</key><string>faceauth</string>
    <key>CFBundleDisplayName</key><string>faceauth</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signatures, inside out (no Developer ID, not notarized).
codesign --force --sign - "$R/faceauth" "$R/pam_faceauth.so"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"

ln -s /Applications "$WORK/dmg/Applications"
cat > "$WORK/dmg/READ ME FIRST.txt" <<TXT
faceauth $VERSION: 2D face unlock prototype for sudo (learning project)

1. Drag faceauth.app onto Applications.
2. Open faceauth from Applications and follow steps 1-5 in its window.
   Each button opens Terminal for that step; you type your password there.

This is weaker than your password, Touch ID or Face ID. If the face check
fails, sudo asks for your password. Only /etc/pam.d/sudo_local is changed.
The app is ad-hoc signed and not notarized: it is meant for the Mac it was
built on.
TXT

mkdir -p dist
OUT="dist/faceauth-app-$VERSION.dmg"
rm -f "$OUT"
hdiutil create -volname "faceauth" -srcfolder "$WORK/dmg" -ov -format UDZO "$OUT" >/dev/null
shasum -a 256 "$OUT" | tee "$OUT.sha256"
ls -lh "$OUT"
