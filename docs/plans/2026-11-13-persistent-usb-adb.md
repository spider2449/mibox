# Persist USB ADB on the stock MiBOX1S system

Authorization: owner explicitly requested a permanent setting change after
confirming the stock menu returns to Deny after reboot.

1. [x] Identify the installed initialization code that clears adb_enabled.
2. [x] Confirm the existing oneshot root post-boot service and back up its script.
3. [x] Prepare a small append-only hook, atomic installer and rollback path.
4. [x] Install preserving original owner/mode/SELinux label; restore /system RO.
5. [x] Verify installed bytes, settings and file metadata before reboot.
6. [x] Reboot once and verify a changed boot ID, hook completion, adb_enabled=1,
   USB config adb and a stable USB shell without manual re-enabling.
7. [x] Record the exact change, before/after evidence and rollback command.

Use the existing /system/etc/init.post-boot.sh entry point after Android boot.
Preserve its backup-version query. Wait 20 seconds before re-enabling USB ADB,
so the stock settings service can finish its reset first. No APK/bootloader/boot
image changes, CTS-mode spoofing or permanent network-ADB setting are required.
Backups and an atomic restore operation must exist before replacing the file.

2026-11-14: installation and byte-for-byte readback succeeded. A reboot was
requested at 06:04:22; USB has not returned during initial observation.
Reboot persistence is NOT VERIFIED. Read the hook log after access is restored
before changing the hook or issuing another reboot.

Superseded by V3 on 2026-11-14: reboot verification passed. See
2026-11-14-persistent-adb-v3.md and ../mibox-persistent-usb-adb.md.
