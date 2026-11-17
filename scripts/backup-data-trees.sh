#!/bin/bash
# S2: stream Alpine tree and local/tmp from the RAM console to phone-tools/backup and verify.
# Usage (WSL): scripts/backup-data-trees.sh KNOWN_HOSTS  (known_hosts from run-console-root.py this boot)
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd); cd "$repo"
keysrc=$(wslpath -u "$(cmd.exe /c echo %USERPROFILE% 2>/dev/null | tr -d '\r')")/.ssh/mibox-console
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT; cp "$keysrc" $tmp/key; chmod 600 $tmp/key
known=${1:?known_hosts from this boot}
# Re-confirm host key against USB-read public key for this boot
usbkey=$(phone-tools/platform-tools/adb.exe -s 248243005297 shell cat /etc/dropbear/dropbear_ed25519_host_key.pub | tr -d '\r' | awk '{print $1" "$2}')
case "$usbkey" in "ssh-ed25519 "?*) ;; *) echo NO_USB_HOSTKEY; exit 1;; esac
grep -qxF "192.168.1.222 $usbkey" "$known" || { echo HOSTKEY_MISMATCH; exit 1; }
ssh_() { ssh -i $tmp/key -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$known -o ConnectTimeout=10 root@192.168.1.222 "$@"; }
ev=artifacts/storage/s2-$(date +%Y%m%d); out=phone-tools/backup/$(date +%Y-%m-%d)-s2; mkdir -p $ev $out
ssh_ 'sh -s list' < scripts/device/s2-tree-backup.sh > $ev/device-listing.txt
ssh_ "sh -s hashes" < scripts/device/s2-tree-backup.sh > $ev/device-sha256.txt
ssh_ "sh -s tar mibox-console" < scripts/device/s2-tree-backup.sh > $out/mibox-console.tar
ssh_ "sh -s tar local/tmp" < scripts/device/s2-tree-backup.sh > $out/local-tmp.tar
cp "$known" $ev/known_hosts
ls -l $out; wc -l $ev/device-listing.txt
python3 -I scripts/verify-tree-backup.py $ev/device-listing.txt $ev/device-sha256.txt $ev/backup-verification.json $out/mibox-console.tar $out/local-tmp.tar
