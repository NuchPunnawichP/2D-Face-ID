#!/bin/sh
# Installs faceauth for sudo (Milestone 2). Run from the repository root:
#   sh pam/install.sh
# It uses sudo for each system change and touches only:
#   /usr/local/libexec/faceauth, /usr/local/share/faceauth/, /usr/local/lib/pam/pam_faceauth.so,
#   /etc/pam.d/sudo_local   (never /etc/pam.d/sudo)
# BEFORE running: open a second Terminal and run `sudo -s` there, and keep it
# open until you have tested that sudo still works (see README, "Recovery").
set -eu

LINE='auth       sufficient     /usr/local/lib/pam/pam_faceauth.so path=/usr/local/libexec/faceauth timeout=10'

[ -x .build/release/faceauth ] || { echo "Build first: swift build -c release"; exit 1; }
[ -d models/MobileFaceNet.mlpackage ] || { echo "Convert the model first (README, Setup)"; exit 1; }
[ -f pam/pam_faceauth.so ] || { echo "Build the PAM module first: make -C pam"; exit 1; }

echo "SHA-256 of /etc/pam.d/sudo before: $(shasum -a 256 /etc/pam.d/sudo | cut -d' ' -f1)"

sudo install -d -o root -g wheel -m 755 /usr/local/libexec /usr/local/share/faceauth /usr/local/lib/pam
sudo install -o root -g wheel -m 755 .build/release/faceauth /usr/local/libexec/faceauth
sudo rm -rf /usr/local/share/faceauth/MobileFaceNet.mlpackage
sudo cp -R models/MobileFaceNet.mlpackage /usr/local/share/faceauth/
sudo chown -R root:wheel /usr/local/share/faceauth
sudo chmod -R go-w /usr/local/share/faceauth
sudo install -o root -g wheel -m 444 pam/pam_faceauth.so /usr/local/lib/pam/pam_faceauth.so

if [ -f /etc/pam.d/sudo_local ]; then
    sudo cp -p /etc/pam.d/sudo_local /etc/pam.d/sudo_local.faceauth-backup
    if grep -q pam_faceauth.so /etc/pam.d/sudo_local; then
        echo "/etc/pam.d/sudo_local already has pam_faceauth; leaving it as is."
    else
        # Our line goes first, so the face is tried before Touch ID / password.
        { echo "$LINE"; cat /etc/pam.d/sudo_local.faceauth-backup; } | sudo tee /etc/pam.d/sudo_local.new >/dev/null
        sudo mv /etc/pam.d/sudo_local.new /etc/pam.d/sudo_local
    fi
else
    { cat /etc/pam.d/sudo_local.template; echo "$LINE"; } | sudo tee /etc/pam.d/sudo_local >/dev/null
    sudo touch /etc/pam.d/.sudo_local.created-by-faceauth
fi
sudo chown root:wheel /etc/pam.d/sudo_local
sudo chmod 444 /etc/pam.d/sudo_local

echo "SHA-256 of /etc/pam.d/sudo after:  $(shasum -a 256 /etc/pam.d/sudo | cut -d' ' -f1)"
echo
echo "Installed. /etc/pam.d/sudo_local is now:"
cat /etc/pam.d/sudo_local
echo
echo "Test in a NEW Terminal tab: sudo -k; sudo true"
