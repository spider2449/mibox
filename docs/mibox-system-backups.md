# System partition backups, 2026-11-14

Both 512 MiB partitions were copied to this PC, with all 64 MiB chunk hashes
and full raw-image hashes verified against device-side reads.

| Source | Host image | SHA256 |
| --- | --- | --- |
| system1 | phone-tools/backup/systems-20261114-072524/system1.img | 55ee5a9cce011b3eb0ce3ef5b0a15c376275ce05dcb5159aee0dc2e321293d93 |
| system | phone-tools/backup/systems-20261114-073129/system.img | 114cc4790af61988944bb39adecc141ae2da80fcf20f30689ac152fb8b3cc99c |

Manifest: artifacts/system-backups/2026-11-14/verified-systems.json. Chunks are
retained alongside the assembled images. The active system1 snapshot includes
the verified V3 USB ADB hook; it is not an untouched factory system image.
Read-only debugfs inspection confirms the expected ext4 filesystem, script and
SELinux file label; no -w option was used. Its command file and transcript are
retained in the same artifact directory.

The source reader never opens a block device for writing. Active system1 has
block read-only=1. Inactive system has block read-only=0, so the reader checks
it is unmounted by comparing device numbers, including alternate device paths,
before every chunk and final hash. It does not change either flag or mount.

/data had about 479 MiB free initially. A full 512 MiB staging file would not
fit. scripts/Backup-MiboxSystems.ps1 stages at most one 64 MiB chunk, pulls it,
validates length/hash, appends it to a host image, then removes only the exact
verified scratch image. Small task logs remain. Final /data free space was
about 476 MiB, including the separately preserved incomplete eMMC boot read.

Reproduce after building/pushing mibox-backup-system:

```powershell
cargo build --release --bin mibox-backup-system
powershell -NoProfile -File scripts/Backup-MiboxSystems.ps1
```

The script also accepts -Partitions system or -Partitions system1 and preserves
previous verified partition records. It refuses mismatched sizes/hashes.

## Separate incomplete hardware-boot-area read

The existing seven named partition backups are distinct from eMMC hardware
boot0/boot1 regions. /dev/block/bootloader is device 179:1, while mmcblk0boot0
is 179:16. A read-only attempt to back up mmcblk0boot0 stopped with I/O error
after 2093056 of 2097152 bytes. That partial file does not match the named
bootloader image prefix and contains no matched U-Boot/fastboot banner strings.
It is INCOMPLETE and MUST NOT be used for restoration. boot1 was not attempted
after this failure. No hardware-boot-area write or configuration change occurred.

Partial retained privately at phone-tools/backup/emmc-boot-2026-11-14/;
metadata/error at artifacts/platform/2026-11-14/emmc-boot-partial.json and
emmc-boot-read-error.txt. Do not describe these backups as a full disk snapshot
or a tested recovery procedure. Userdata is not included.
