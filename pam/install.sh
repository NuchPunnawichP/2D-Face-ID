#!/bin/sh
# Installs faceauth for sudo (Milestone 2). Run either
#   - from the repository root:  sh pam/install.sh
#   - or from the mounted DMG:   sh /Volumes/faceauth/install.sh
# It uses sudo for each system change and touches only:
#   /usr/local/libexec/faceauth, /usr/local/share/faceauth/, /usr/local/lib/pam/pam_faceauth.so,
#   /etc/pam.d/sudo_local   (never /etc/pam.d/sudo)
# The sudo enrollment itself is created later by `enroll --system` in /var/db/faceauth/.
# BEFORE running: open a second Terminal and run `sudo -s` there, and keep it
# open until you have tested that sudo still works (see README, "Recovery").
set -eu

LINE='auth       sufficient     /usr/local/lib/pam/pam_faceauth.so path=/usr/local/libexec/faceauth timeout=10'
SHARE=/usr/local/share/faceauth
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Files come from the DMG (next to this script) or from a repository build.
HERE=$(cd "$(dirname "$0")" && pwd)
if [ -x "$HERE/faceauth" ] && [ -d "$HERE/MobileFaceNet.mlpackage" ] && [ -f "$HERE/pam_faceauth.so" ]; then
    BIN="$HERE/faceauth"; MODEL="$HERE/MobileFaceNet.mlpackage"; PAMSO="$HERE/pam_faceauth.so"
else
    BIN=.build/release/faceauth; MODEL=models/MobileFaceNet.mlpackage; PAMSO=pam/pam_faceauth.so
    [ -x "$BIN" ] || { echo "Build first: swift build -c release"; exit 1; }
    [ -d "$MODEL" ] || { echo "Convert the model first (README, Setup)"; exit 1; }
    [ -f "$PAMSO" ] || { echo "Build the PAM module first: make -C pam"; exit 1; }
fi
echo "Installing from: $BIN, $MODEL, $PAMSO"

echo "SHA-256 of /etc/pam.d/sudo before: $(shasum -a 256 /etc/pam.d/sudo | cut -d' ' -f1)"

sudo install -d -o root -g wheel -m 755 /usr/local/libexec "$SHARE" /usr/local/lib/pam
sudo install -o root -g wheel -m 755 "$BIN" /usr/local/libexec/faceauth
sudo rm -rf "$SHARE/MobileFaceNet.mlpackage"
sudo cp -R "$MODEL" "$SHARE/MobileFaceNet.mlpackage"
sudo chown -R root:wheel "$SHARE"
sudo chmod -R go-w "$SHARE"
# Compile the model once, as root, into a root-owned .mlmodelc. The verifier and
# the capture helper (which run as you) load it directly: no compile step and
# no user-writable cache under sudo.
sudo /usr/local/libexec/faceauth install-model
sudo chown -R root:wheel "$SHARE"
sudo chmod -R go-w "$SHARE"
# Every parent directory must be root-owned and not writable by others.
for d in /usr /usr/local /usr/local/share /usr/local/libexec /usr/local/lib; do
    owner=$(stat -f %u "$d"); perm=$(stat -f %Lp "$d")
    if [ "$owner" != 0 ] || [ $((0$perm & 022)) != 0 ]; then
        echo "WARNING: $d is not root-owned or is writable by others (owner $owner, mode $perm)."
        echo "         faceauth will refuse to run under sudo until this is fixed."
    fi
done
sudo install -o root -g wheel -m 444 "$PAMSO" /usr/local/lib/pam/pam_faceauth.so

# Record the original state once (outside /etc/pam.d, so it is never read as a PAM service).
if [ ! -e "$SHARE/sudo_local.state" ]; then
    if [ -f /etc/pam.d/sudo_local ]; then
        sudo cp -p /etc/pam.d/sudo_local "$SHARE/sudo_local.original"
        echo existed | sudo tee "$SHARE/sudo_local.state" >/dev/null
    else
        echo absent | sudo tee "$SHARE/sudo_local.state" >/dev/null
    fi
fi

if [ -f /etc/pam.d/sudo_local ] && grep -q pam_faceauth.so /etc/pam.d/sudo_local; then
    echo "/etc/pam.d/sudo_local already has pam_faceauth; leaving it as is."
else
    if [ -f /etc/pam.d/sudo_local ]; then
        # Our line goes first, so the face is tried before Touch ID / password.
        { echo "$LINE"; cat /etc/pam.d/sudo_local; } > "$TMP/sudo_local"
    else
        { cat /etc/pam.d/sudo_local.template; echo "$LINE"; } > "$TMP/sudo_local"
    fi
    sudo install -o root -g wheel -m 444 "$TMP/sudo_local" /etc/pam.d/sudo_local
fi

echo "SHA-256 of /etc/pam.d/sudo after:  $(shasum -a 256 /etc/pam.d/sudo | cut -d' ' -f1)"
echo
echo "Installed. /etc/pam.d/sudo_local is now:"
cat /etc/pam.d/sudo_local
echo
echo "Next, enroll your face for sudo (root-owned copy in /var/db/faceauth/$(id -u)/):"
echo "  sudo /usr/local/libexec/faceauth enroll --system"
echo "  sudo /usr/local/libexec/faceauth calibrate --system"
echo "Until then sudo simply asks for your password."
echo "Then test in a NEW Terminal tab: sudo -k; sudo true"
