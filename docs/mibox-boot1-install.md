# Writing and restoring boot1 (plan C3)

Status: **boot1 WRITTEN with Slim `dd1e6756…` on 2026-11-17 (owner-authorized C4).**
Stock boot1 `06d9eb7e…` remains restorable with the restore section below. Writing boot1
(C4) needs explicit owner approval at that time. Nothing here touches the
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
