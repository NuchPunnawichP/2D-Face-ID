#!/bin/sh
# Removes faceauth from sudo and deletes the installed files.
# Your enrollment in ~/Library/Application Support/faceauth is kept; delete it
# yourself with: rm -rf ~/Library/Application\ Support/faceauth
set -eu
if [ -f /etc/pam.d/.sudo_local.created-by-faceauth ]; then
    sudo rm -f /etc/pam.d/sudo_local /etc/pam.d/.sudo_local.created-by-faceauth
elif [ -f /etc/pam.d/sudo_local ]; then
    grep -v 'pam_faceauth.so' /etc/pam.d/sudo_local | sudo tee /etc/pam.d/sudo_local.new >/dev/null
    sudo mv /etc/pam.d/sudo_local.new /etc/pam.d/sudo_local
    sudo chown root:wheel /etc/pam.d/sudo_local
    sudo chmod 444 /etc/pam.d/sudo_local
fi
sudo rm -f /usr/local/lib/pam/pam_faceauth.so /usr/local/libexec/faceauth
sudo rm -rf /usr/local/share/faceauth
echo "faceauth removed from sudo. Test: sudo -k; sudo true (should ask for your password)"
