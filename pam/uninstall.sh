#!/bin/sh
# Removes faceauth from sudo and deletes the installed files.
# Only the pam_faceauth line is removed from /etc/pam.d/sudo_local; any other
# lines (e.g. pam_tid for Touch ID) are kept. If the installer created the file
# and nothing but comments remains, the file is removed.
# Your enrollment in ~/Library/Application Support/faceauth is kept; delete it
# yourself with: rm -rf ~/Library/Application\ Support/faceauth
set -eu
SHARE=/usr/local/share/faceauth
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if [ -f /etc/pam.d/sudo_local ]; then
    grep -v 'pam_faceauth.so' /etc/pam.d/sudo_local > "$TMP/sudo_local" || true
    state=$(cat "$SHARE/sudo_local.state" 2>/dev/null || echo unknown)
    if [ "$state" = absent ] && ! grep -qvE '^[[:space:]]*(#|$)' "$TMP/sudo_local"; then
        sudo rm -f /etc/pam.d/sudo_local
    else
        sudo install -o root -g wheel -m 444 "$TMP/sudo_local" /etc/pam.d/sudo_local
    fi
fi
sudo rm -f /usr/local/lib/pam/pam_faceauth.so /usr/local/libexec/faceauth
sudo rm -rf "$SHARE"

# The root-owned sudo enrollments (biometric data): show them and ask (Q23).
if sudo test -d /var/db/faceauth; then
    echo
    echo "Root-owned sudo enrollments in /var/db/faceauth:"
    sudo find /var/db/faceauth -mindepth 1 -print
    printf "Delete /var/db/faceauth and everything in it? [y/N] "
    read -r answer
    case "$answer" in
        y|Y|yes|YES) sudo rm -rf /var/db/faceauth; echo "Deleted /var/db/faceauth." ;;
        *) echo "Kept /var/db/faceauth (delete later with: sudo rm -rf /var/db/faceauth)." ;;
    esac
fi
echo "faceauth removed from sudo. Test: sudo -k; sudo true (should ask for your password)"
