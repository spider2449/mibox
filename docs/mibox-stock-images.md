# Acquired stock images (2026-11-13)

## Backup result

Windows recorded the USB device returning at 22:04:27. Shell then responded.
The fixed backup tool ran through the already established local root command
path. Its first attempt used Android toolbox mkdir with unsupported -m; that
attempt produced no backup directory. The tool was corrected to use BusyBox
mkdir and to check directory creation before reading partitions.

The completed run printed MIBOX_BOOT_BACKUP_OK and remote exit 0. It created
`/data/local/tmp/mibox-boot-backup-5877/`. Seven image files were copied to
`phone-tools/backup/2026-11-13/` on this PC. Their SHA-256 hashes all matched
hashes computed on the device. Full manifest:
`artifacts/boot-evidence/2026-11-13/verified-backups.json`.

| Image | Bytes |
| --- | ---: |
| boot.img | 8388608 |
| boot1.img | 8388608 |
| recovery.img | 8388608 |
| bootloader.img | 2097152 |
| env.img | 4194304 |
| reserved.img | 2097152 |
| logo.img | 4194304 |

These are backups of the named partitions, not a full disk/data backup. Original
partitions were only read; scratch files were written to Android's /data area.
Neither system nor userdata was erased. A restore procedure has not been tested.

## Which image matches the installed recovery script?

- boot1.img first 4433609 bytes: SHA-1
  `2dafa19e539ef3a5a674d3f13ff6df9ab483220f`, matching the installed script.
- boot.img first 4433609 bytes: SHA-1
  `09c5747e5f5fe5debb98e78b84af999877e1ffe1`, different.
- recovery.img first 6794846 bytes: SHA-1
  `e94825710e912cc47f09dee1be17fb43d1fc564d`, matching the script.

This identifies boot1 as the expected recovery-patch source. It does not alone
establish which boot partition the bootloader selected for this running session.

## boot1 layout

The bounded offline parser found ANDROID! at offset 0, 2048-byte pages and an
Android-v0-compatible header. Recomputed Android image ID matches its header.

| Section | File offset | Bytes |
| --- | ---: | ---: |
| kernel | 2048 | 3897711 |
| gzip ramdisk | 3901440 | 519629 |
| second | 4421632 | 11414 |

The second section starts with FDT magic; its declared total size equals the
11414-byte section. This is a candidate stock DTB, not an invented board DTS.
The ramdisk decompresses to 908032 bytes and has a valid parsed cpio trailer.
Selected init/fstab/property files were extracted without executing them.
Extracted files remain under `phone-tools/extracted/2026-11-13/`.

The header declares addresses kernel=0x10008000, ramdisk=0x11000000,
second=0x10f00000, tags=0x10000100. These are observed header values, not validated
RAM-boot commands. Contents after section bounds and any loader signature policy
still need analysis. No boot image was modified, repacked or booted.

## Next step

Inspect the actual stock DTB, init scripts, bootloader and image tail to establish
RAM layout, console, signature/loader requirements and a nonpersistent test path.
Build custom PID1 only against those verified platform facts. Preserve the stock
kernel and DTB during the first custom-userspace boot experiment.
