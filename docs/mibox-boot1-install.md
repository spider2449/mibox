# Writing and restoring boot1 (plan C3)

Status: **boot1 holds the container-kernel Slim `614861f6…` (SlimKernelDev13: Dev12
plus the backported pids cgroup controller) since 2026-11-25**
(`artifacts/console-root/20261125-205240-c10-dev13-boot1-write/`), after `772c2210…`
(Dev12: Dev10 plus the atomic-context kernel fixes and `mibox-netwatch` default-route
recovery, `artifacts/console-root/20261124-205717-c9-dev12-boot1-write/`), `760288f6…` (Dev10: 3.10.99 with board patches, Docker with dockerd in its own mount
namespace, live HDMI screen with a SoC temperature card, SSH password logins allowed,
`artifacts/console-root/20261119-222407-c8-temp-boot1-write/`), `c3e952e8…`
(Dev9, `artifacts/console-root/20261119-220022-docker-ns-boot1-write/`), `0d549c0f…`
(Dev8), `bccbad4f…` (Dev7), C4
(`dd1e6756…`), two A5 rewrites (`35e1d4d2…`, `f11de99e…`) and A5b (`955ea3e8…`,
stock 3.10.33 kernel), all owner-approved. A flash boot without the PC came up
with SSH, Docker and the HDMI screen. For a restore, name the current image as the
expected current content (`614861f6…`; before it `772c2210…`, `760288f6…`, `c3e952e8…`, `0d549c0f…`, before the password change `bccbad4f…`); `955ea3e8…` (`target/mibox-boot-candidate-slim-fbstatus/`)
is the last stock-kernel image.
Stock boot1 `06d9eb7e…` remains restorable with the restore section below. Writing boot1
(C4) needs explicit owner approval at that time. Apart from the S8 section at the end (boot), nothing here touches the
bootloader, env, boot, recovery, system or data partitions.

## Why boot1, and why it is recoverable

- C1 (`mibox-boot-selection.md`): with the installed env (`6142e34f…`,
  `bootsystem=1`) a cold start reads boot1 (179:7).
- The USB loader window (`update 10000;`) is the first command of `preboot`,
  which runs before `storeboot` reads boot1. A power cycle with the PC attached
  therefore reaches C003 whatever boot1 contains; FailSafe/Slim then load into
  RAM as today (`mibox-rescue-procedure.md`). C2 showed that without the PC the
  window expires and boot1 starts.
- If `bootm` rejects boot1, `storeboot` continues with `run recovery`.

## Inputs (pinned)

| Item | SHA256 |
| --- | --- |
| Current boot1 = stock backup `phone-tools/backup/2026-11-13/boot1.img` | `06d9eb7e4c93ff97bcaff7dc0f4d274ddd8a51efe8bd3639bca2cc31f8314222` |
| Candidate: Slim `target/mibox-boot-candidate-slim/boot1-custom.NOT_READY.img` | `dd1e6756bbbc8b5b5f268ac3b79a11ded792a6c4ee7ad43318ab641de3b14f2e` |
| Tool `mibox-partwrite` (armv7 static, built from `src/bin/mibox-partwrite.rs`) | `e4750d65206780f16a44a957188a87a591d24f1dbdfe16ba8acb0c2d9707d1ec` |

A read-only dry run from FailSafe (RAM root, no data mounted) passed on 2026-11-17
(`artifacts/console-root/20261117-211336-c3-failsafe-prep/`).

Re-confirm before use: `scripts/verify-boot-backups.py` (A3a) passes for the
backup and the candidate, and the device's boot1 still hashes `06d9eb7e…`.

## The tool

`mibox-partwrite --target boot1 --image PATH --image-sha256 HEX
--expect-current-sha256 HEX [--dry-run]`, run as root with a RAM root
(`chroot /proc/1/root …` from an Alpine SSH session):

- only target `boot1` on the stock Meson6: sysfs name boot1, 179:7,
  16384 sectors, `ro=0`, not mounted; opened through a private node created
  from the verified major:minor (removed afterwards);
- image exactly 8388608 bytes with the given hash;
- refuses unless boot1's current content has `--expect-current-sha256`
  (reports `AlreadyInstalled` and writes nothing if it already equals the image);
- writes with O_SYNC|O_EXCL, `fsync`, `BLKFLSBUF`, then re-reads all
  8388608 bytes; the hash must equal the image (`READBACK MISMATCH` otherwise).

## Write (C4, owner approval required)

1. Box on Slim or FailSafe in RAM, PC attached, data may stay mounted (boot1
   is never mounted). Confirm `adb … shell cat /proc/sys/kernel/random/boot_id`.
2. Upload tool and candidate into RAM (`/proc/1/root/tmp`), check both hashes.
3. Dry run: `--image /tmp/slim.img --image-sha256 dd1e6756… --expect-current-sha256 06d9eb7e… --dry-run`
   must print `DryRunVerified`.
4. Write: the same without `--dry-run`; must print
   `MIBOX_PARTWRITE_READBACK_VERIFIED=dd1e6756…` and `RESULT=Written`.
5. Independent second collection, separate command:
   `echo 3 > /proc/sys/vm/drop_caches; dd if=<boot1 node> bs=65536 | sha256sum`
   (node via `scripts/device/a3a-hash-boot-partitions.sh`) must give `dd1e6756…`.
6. Remove uploads. Verification of the result is C5 (cold start without PC).

## Restore (back to stock boot1)

From any custom RAM system with root (Slim, or FailSafe after a power cycle
with the PC attached -> C003):

1. Upload the tool and `boot1.img` (`06d9eb7e…`).
2. `--image /tmp/boot1.img --image-sha256 06d9eb7e… --expect-current-sha256 <current>`
   where `<current>` is the hash read in step 5 above (normally `dd1e6756…`).
   If boot1's content is unknown, first hash it read-only and name that hash.
3. Same readback and independent re-hash, expecting `06d9eb7e…`.

## Rehearsal evidence

The dry runs below used the earlier Slim `87daa0d3…`; the tool is image-agnostic.
The current candidate `dd1e6756…` (B2 baseline, PID1 SSH supervision) passed
A3a-style checks via `verify-boot-backups.py` in the same session.

- Host unit tests (`cargo test --target x86_64-unknown-linux-gnu --bin mibox-partwrite`):
  7 pass — SHA-256 vectors, write then restore, refusals leave the target
  unchanged, wrong target size, already installed, readback corruption reported
  and a blind retry refused, strict hex.
- QEMU virtio block device (`scripts/test-partwrite-qemu.py`), 15 checks pass
  (`artifacts/partwrite-qemu/20261117-210900/`): platform/hash/size refusals
  with the disk unchanged, dry run, Slim write with readback and independent
  re-hash, `AlreadyInstalled`, restore of the boot1 backup with readback,
  host-side file equals the backup.
- Real box, read-only dry run (`artifacts/console-root/20261117-211020-c3-dryrun-prep/`):
  boot1 resolved to 179:7, current content `06d9eb7e…` verified, wrong
  expected hash and target `boot` refused, nothing written.

## Not covered

- eMMC durability across power loss during the write (a partial boot1 is
  recovered by the restore path above, via C003).
- Whether `bootm` from flash accepts the Slim image (C4/C5); RAM `bootm` via
  C003 does.
- Without the PC, a Slim that fails early restarts through the fail-safe and
  loops; recovery then needs the PC attached (rescue procedure limits).

## SoC temperature on the HDMI screen (Dev10)

Neither the stock nor the 3.10.99 config enables `MESON_CPU_TEMP_SENSOR`, so
there is no thermal zone. `mibox-slim-start` writes `1` to
`/sys/class/saradc/saradc_temperature` once before starting `mibox-fbstatus`
(SARADC channel 6 -> on-die sensor, tempsen mode 2; the driver logs
`enter temperature mode`) and creates `/run/mibox-cpu-temp`. fbstatus reads
`saradc_ch6` once a second and shows the 8-sample mean of
`raw * 0.23077 - 88` (the vendor driver's meson6 formula, untrimmed), plus the
peak since start; amber from 75 C, red from 85 C, `N/A` without the marker.
Writing `0` returns channel 6 to its normal input. After the Dev10 flash boot
the screen showed 73 C (peak 78 during boot); raw 686-726 under light load.

## boot (179:6) as a fallback copy (plan S8)

Since tool `ee69569f…` (2026-11-27) `mibox-partwrite` also accepts
`--target boot` on the Meson6 (179:6, same size/ro/mount/hash guards); every
other partition is still refused. A default/reset env boots `boot` and has no
USB window, so a Slim copy there keeps the box reachable over SSH. Stock boot
`ff4fa440…` is `phone-tools/backup/2026-11-13/boot.img`; restore it with the
same tool and `--target boot`. Real-box dry run:
`artifacts/console-root/20261127-220131-s8-boot-dryrun/`. Writing it needs
explicit owner approval.

Written 2026-11-27 (owner-approved): boot = `614861f6…` (same Dev13 as boot1),
readback and independent re-hash verified
(`artifacts/console-root/20261127-220257-s8-boot-write/`). Restore expect-current
for boot is now `614861f6…`. Never boot-tested: only a default/reset env reads boot.
