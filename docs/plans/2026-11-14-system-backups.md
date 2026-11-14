# Verified system partition backups

1. [x] Verify source partition geometry, protection and available scratch space.
2. [x] Build a fixed reader limited to system/system1, 512 MiB, 64 MiB chunks.
3. [x] Copy each chunk to host, compare SHA256 and release only its known scratch file.
4. [x] Assemble host images and compare full-image hashes against root device reads.
5. [x] Preserve manifest and confirm ADB and protection state.

/data has about 479 MiB free, insufficient for a full raw partition image.
Never stage a 512 MiB image there. Keep at most one 64 MiB chunk on the device;
Active system1 remains block-read-only. The inactive system partition has ro=0
but is unmounted; the reader checks device numbers against all mounted block
sources before every chunk and full hash. No flags are changed. Full source
hash must match the assembled host image. No mount or block write is involved.

system1 verified full SHA256:
55ee5a9cce011b3eb0ce3ef5b0a15c376275ce05dcb5159aee0dc2e321293d93.
Initial inactive-system attempt was refused by the stricter block-ro check;
the updated unmounted-source check permits read-only backup without changing it.

An additional eMMC boot0 read returned I/O error at 2093056/2097152 bytes;
it is an INCOMPLETE backup and must not be used as a restore image. No boot0
write was attempted. Fixed root diagnostic preserved the dd error.

Both system and system1 complete images are verified. See
docs/mibox-system-backups.md for paths/hashes, source protection and exclusions.
USB ADB remains enabled, SELinux Enforcing and active system1 block-read-only=1.
