#!/bin/sh
# Builds dist/faceauth-<version>.dmg containing everything pam/install.sh needs:
#   faceauth (release binary), pam_faceauth.so, MobileFaceNet.mlpackage,
#   install.sh, uninstall.sh, README, SPEC, licenses.
# Usage (from the repository root):  sh scripts/make_dmg.sh [version]
# Needs the converted model in models/ (see README, Setup). Does not need sudo.
set -eu
VERSION=${1:-0.1.0}
cd "$(dirname "$0")/.."

[ -d models/MobileFaceNet.mlpackage ] || { echo "Convert the model first: scripts/.venv/bin/python -I scripts/convert_model.py"; exit 1; }
swift build -c release
make -C pam pam_faceauth.so

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/faceauth"
mkdir -p "$STAGE/licenses"
cp .build/release/faceauth pam/pam_faceauth.so pam/install.sh pam/uninstall.sh "$STAGE/"
cp -R models/MobileFaceNet.mlpackage "$STAGE/"
cp README.md "$STAGE/README.md"
cp SPEC.md "$STAGE/SPEC.md"
cp licenses/MobileFaceNet-LICENSE licenses/NOTICE.md "$STAGE/licenses/"
chmod 755 "$STAGE/faceauth" "$STAGE/install.sh" "$STAGE/uninstall.sh"

# Ad-hoc signatures (no Developer ID): fine for this Mac. A DMG downloaded
# from the internet would be quarantined; see READ ME FIRST.
codesign --force --sign - "$STAGE/faceauth" "$STAGE/pam_faceauth.so"

cat > "$STAGE/READ ME FIRST.txt" <<TXT
faceauth $VERSION: 2D face unlock prototype for sudo (learning project)

This is weaker than your password, Touch ID or Face ID. Read README.md, section
"Security limitations", before installing.

1. Open a second Terminal window and run: sudo -s
   Keep it open until you have tested sudo (it is your way back).
2. In another Terminal window:
     sh /Volumes/faceauth/install.sh
3. Enroll and calibrate for sudo (5 live snaps, then live vs. phone photo):
     sudo /usr/local/libexec/faceauth enroll --system
     sudo /usr/local/libexec/faceauth calibrate --system
4. Test in a new tab:  sudo -k; sudo true
   (If the face check fails or times out, sudo asks for your password.)

Remove everything:  sh /Volumes/faceauth/uninstall.sh

Only /etc/pam.d/sudo_local is changed, never /etc/pam.d/sudo. The login window
and lock screen are not touched. Binaries are ad-hoc signed, not notarized.
TXT

mkdir -p dist
OUT="dist/faceauth-$VERSION.dmg"
rm -f "$OUT"
hdiutil create -volname faceauth -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null
shasum -a 256 "$OUT" | tee "$OUT.sha256"
ls -lh "$OUT"
