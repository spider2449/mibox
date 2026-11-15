# System redesign: stock kernel, persistent Alpine, independent boot

Date: 2026-11-15. Revised after comparison with `amazing-a32-os`.
This is an implementation plan, not authorization to execute device operations.
Existing baseline results below remain distinct from unfinished acceptance gates.

## Architecture and baseline

Follow the working A32 architecture: keep the stock kernel and a small RAM
initramfs containing the custom PID1 and recovery tools. Mount the existing data
filesystem and start Alpine services in a chroot. PID1 stays outside Alpine and
owns service supervision, recovery and orderly restart. `switch_root` and a
replacement kernel are not prerequisites.

A32's README records flash boot, persistent `/data/alpine`, SSH, restart and one
power-cut recovery test. Those are architectural references, not MiBOX hardware
proof. A32 has a 16 MiB boot partition and an unlocked bootloader/fastboot path;
MiBOX has 8 MiB boot partitions and the separately verified C003 control path.

| MiBOX fact | Evidence and consequence |
| --- | --- |
| Pinned Console RAM boot works | Stock kernel + custom PID1, full 8 MiB upload/readback/hash before boot; retain this rescue candidate |
| Persistent Alpine already exists | `docs/mibox-console-ssh.md`, `assets/rootfs/mibox-persistent-console`: `/mnt/mibox-data/mibox-console/rootfs`; currently activated by a host launcher |
| Boot image limit is 8 MiB | Existing Console image uses 8343552 bytes, leaving 45056 bytes; recalculate for every new candidate |
| Pending display additions overflow | Existing estimates: fbhandoff 357572 bytes static, about 209 KB gzip, plus about 9 KB gzip splash; measure the final combined image |
| Stock kernel is already LZMA-compressed | Legacy uImage payload 3897647 bytes, expanded size 11878528; preserve its container and load/entry addresses (`docs/mibox-runtime-console-watchdog.md`) |
| Embedded stock config is available | `CONFIG_IKCONFIG_PROC=n`: use `artifacts/platform/2026-11-14/kernel-config.json` and extracted config, not `/proc/config.gz` (`docs/mibox-software-boot-analysis.md`) |
| Rescue transfer is slow | Full 8 MiB control transfer took about 1311 seconds; shrinking payload alone does not change the current fixed-size transfer workflow |
| Bulk remains disabled | Correct-framing probe failed with host native 87 and loader stopped answering; descriptors confirm endpoints, but do not establish the fault's location (`docs/mibox-usb-loader-protocol.md`) |
| Host-attached cold rescue works | Cold power -> C003 -> pinned RAM console without Android; host-disconnected deadline expiry/continuation remains unobserved (`docs/mibox-independent-rescue.md`) |

Measured partition layout: bootloader 2 MiB, reserved 2 MiB, env 4 MiB,
logo 4 MiB, recovery 8 MiB, boot 8 MiB, boot1 8 MiB, system 512 MiB,
system1 512 MiB, cache 192 MiB, data 2.5 GiB.
Source: `artifacts/partitions/layout.json`. Historical verified backups include
env (2026-11-15), boot/boot1 (2026-11-13), and system/system1 (2026-11-14).
Recheck their exact paths, sizes and hashes before using them for restoration.

## Phase A — prepare the small RAM supervisor and persistent userspace

A1. [ ] Inventory the current pinned Console initramfs and existing persistent
   Alpine tree. Record compressed/uncompressed sizes, required binaries and
   libraries, installed packages, free data space and current service startup.
   Separate what early PID1/recovery needs from what can run in Alpine.
A2. [ ] Preserve `/mnt/mibox-data/mibox-console/rootfs` as the canonical Alpine
   tree. Before changing it, create and verify a recoverable backup of that tree,
   configuration and keys. Do not duplicate the whole distribution, format data,
   or overwrite unrelated Android files. Device identity gates remain 179:11,
   5168640 sectors and the existing ext4 filesystem.
A3. [ ] Build a separate slim initramfs with custom PID1, authenticated USB ADB,
   required BusyBox applets/libraries, fixed-IP network setup, the data/chroot
   lifecycle helper and a usable RAM recovery shell. Keep SSH in RAM only if
   needed for recovery; otherwise start it in Alpine. Do not add DHCP by default:
   the current verified network uses owner-confirmed static IPv4.
A4. [ ] Preserve stock kernel/uImage, DTB, cmdline and load addresses. Recalculate
   Android header sizes, section offsets, alignment and total size for the new
   ramdisk; independently inspect and hash the resulting image. Target a
   compressed initramfs <= 1.5 MiB if the required functions fit; the mandatory
   limit is the complete image <= 8388608 bytes with measured slack.
A5. [ ] Add fbhandoff and splash after slimming provides sufficient measured
   capacity. Record final image size and slack; optional display assets must not
   block a functional independent console boot.

Optional space experiment, only if needed: inspect the already extracted config
for `CONFIG_RD_GZIP`, `CONFIG_RD_LZMA`, `CONFIG_RD_LZ4` and `CONFIG_RD_XZ`.
Keep gzip unless another supported format produces a useful measured saving and
passes a separate physical RAM boot. Missing config entries remain UNKNOWN.
Stock kernel recompilation or changing uImage to zImage is a separate research
track requiring source/config provenance and hardware validation, not a gate
for this plan.

Phase A/B write ordinary files on data; they do not rewrite boot partitions.
Provision persistent-only dependencies before removing their RAM copies. Retain
the old pinned image and a compatible persistent-tree backup for rollback.

## Phase B — automatic Alpine startup, recovery and restart

B1. [ ] PID1 automatically activates the existing Alpine chroot after virtual
   filesystems, authenticated ADB and the verified static network are ready.
   Reuse and harden the existing helper: validate device and filesystem identity,
   mount location, directory ownership/permissions and symlink guards; create
   required dev/devpts/proc/sys binds and clean them up on partial failure.
   No format, automatic filesystem repair or automatic rootfs replacement.
   Deliberate deviation from A32, recorded: A32 runs `e2fsck -p` before mount;
   here ext4 journal replay at mount time is relied on instead, so that PID1
   never silently rewrites a damaged filesystem. Document any future change
   to this policy with its own evidence.
B2. [ ] Define rootfs readiness and integrity checks. Pin expected immutable
   startup files or a versioned baseline manifest in the initramfs; do not trust
   a manifest solely because it sits beside its payload. Treat package upgrades,
   `/etc`, `/root`, logs and keys as explicitly mutable state with a controlled
   baseline-update procedure. Preserve existing packages and owner data.
B3. [ ] Start and supervise the selected Alpine services from the outer PID1.
   Reuse or migrate existing SSH host keys and owner authorized keys with correct
   permissions; verify that server identity survives a restart without the host
   launcher re-pinning a newly generated key. Establish time synchronization
   independent of the host; report unsynchronized time until verified.
B3a. [ ] Optional, A32-proven pattern: PID1 creates a zram swap device sized
   from real RAM (half of measured free RAM, lzo) before any service starts,
   writing the swap header itself so swap does not depend on the chroot.
   Acceptance: one memory-pressure test records swap in use without OOM.
B4. [ ] If data is absent, wrong, full, invalid, or fails to mount/start, keep
   PID1, authenticated USB ADB and a RAM shell available. Do not start partial
   services or overwrite the failed tree. Record failure and allow explicit
   recovery. C003 RAM rescue is available on the next bootloader entry, not as a
   USB service inside the running kernel.
B5. [ ] Extend the restart lifecycle for mounted data. Stop services and sessions,
   synchronize state, unmount chroot binds and data, then request normal restart.
   Existing restart control refuses block filesystem mounts; preserve that guard
   until teardown is verified. A busy/unmount failure must be reported and must
   prevent the normal controlled restart, rather than forcing through it.
B6. [ ] Host/QEMU validation: actual slim rootfs startup and supervision; fixture
   data tree success, absent/invalid data, partial mount cleanup, unexpected
   identity, key persistence, and clean/busy shutdown. Generic QEMU validates
   userspace behavior, not stock Meson6 kernel or bootloader compatibility.
B7. [ ] Physical RAM validation: separately pin the new 8 MiB image, upload and
   fully read back/hash before boot. Verify boot ID, OS/PID1/tool hashes,
   automatic chroot/services, SSH key authentication, static network, persistent
   file I/O and owner-observed HDMI when display additions are included.
   Perform controlled restart and another verified RAM boot; confirm saved
   state and SSH host identity survive without manual persistence activation.
B8. [ ] Physical power-cut acceptance, repeating A32's live-cut test on this
   hardware: from the running persistent system, rewrite large files on data
   while appending and syncing a counter line in a loop; owner removes power
   mid-write; on the next boot record the mount/journal state, ext4 kernel
   messages, intact files and the last synced counter line. One cut shows the
   journal works, not that every cut is harmless; record exactly that scope.

After B, userspace startup is automatic and persistent. Cold starts still need
RAM upload until Phase C passes. No system/system1 redundancy write is included:
`system1` is an existing Android system partition, not a free spare rootfs slot.

## Phase C — permanent custom boot and independent rescue

C1. [ ] Establish actual cold-start boot selection from the current env and
   exact-loader flow, including dynamic `switch_bootpart`/cmdline behavior.
   Static `storeboot=store read boot1 ...` alone is insufficient. Record the
   selected partition and evidence; do not assume boot1 or change slot/env.
C2. [ ] Before boot-partition writes, verify host-disconnected continuation on
   the existing boot setup with owner-controlled power and observation. Measure
   elapsed startup time and result. `update 10000` is not a proven 10-second
   duration. Retain the installed env hash and host-attached cold C003 evidence.
C2a. [ ] Boot-image tail forensics gate, following A32's discipline: audit the
   boot/boot1 backups' region beyond the logical image end (any DER signature
   envelope, opaque final block or zero fill), classifying every tail layer
   before any packaging. The packaging gate fails closed (refuses to emit a
   candidate) while any tail layer remains UNKNOWN. A C003 bootm acceptance
   does not prove the flash boot path accepts the same bytes; the loader may
   apply checks on the flashed image that RAM bootm never exercises. Cross-check
   with `docs/mibox-boot-image-evidence.md` and A32's `a32-boot-image-format.md`
   methodology.
C3. [ ] Prepare a concrete write AND restoration procedure for the proven target:
   exact partition identity/size, current full backup and hashes, original backup,
   pinned new candidate, write/flush/full-readback tools and independent second
   collection. Restoration must be executable from the known-good RAM rescue
   OS without relying on the installed boot image or Alpine tree. Validate host
   safeguards and the read-only recovery prerequisites before requesting approval.
C4. [ ] Once B passes and C1-C3 evidence is ready, obtain explicit owner
   authorization for the specific boot-partition write. Install the identical
   full-size bytes that passed physical RAM validation. Perform one bounded
   write, fsync/cache flush, full 8 MiB readback and independent second collection;
   require exact hash matches before any restart. No automatic retry.
C5. [ ] Owner-observed cold boot with the USB host disconnected: bootloader
   window continues into the custom system from flash, then PID1 automatically
   activates Alpine and SSH. Verify runtime identity, persistent keys/state and
   measured startup time. Follow with a controlled restart back into the custom
   system and verify a new boot ID. Record no RAM upload or Android dependency.
C5a. [ ] Repeat the B8 power-cut test from flash boot: cut power during data
   writes, cold start without a host, and verify the system comes up from flash
   with journal recovery, intact data and no manual intervention. This closes
   the flash-boot loop against real power loss, not only controlled restarts.
C6. [ ] Rehearse host-attached cold C003 interception with the persistent custom
   image installed, then reload the known-good pinned RAM rescue and verify it
   can identify/read the target and access the restoration material. Never damage
   a partition as a test. This proves pre-kernel interception and RAM reload;
   partition restoration remains NOT VERIFIED until an authorized restoration
   write and its independent readback actually pass. Do not equate this with
   automatic recovery from every kernel/PID1 failure or watchdog hang.

Only after C5 passes does the long RAM upload leave the ordinary startup path.
C6 and the documented restoration status define the verified rescue boundary.

## Standing rules and completion criteria

- Keep bootloader, reserved, env, logo, recovery, system and system1 unchanged.
  Only the proven boot/boot1 target may be written at C4 under its explicit gate.
  Preserve the installed preboot window and its verified env hash.
- Device preparation and evidence tooling precede device actions. Physical power
  operations are owner-executed. No automatic retries of writes/mode transitions.
- Raw partition writes require complete verified backups, full readback and an
  independent second collection. Ordinary data-file changes use scoped backups,
  integrity checks and rollback; they are still persistent flash writes.
- Keep original failures and UNKNOWN values. Host tests, generic QEMU, RAM boot,
  flash boot, cold entry and partition restoration are separate evidence classes.

Order: A inventory/backup -> slim candidate and B lifecycle -> host/QEMU checks
-> B physical RAM/restart checks -> C selection, no-host continuation and recovery
preparation -> owner-authorized installation -> standalone cold boot/restart and
rescue rehearsal. C1-C3 read-only analysis/tool preparation may run before B ends.

Completion means stock-kernel custom PID1 boots from flash without a host,
automatically starts persistent Alpine and authenticated SSH, preserves state
and server identity across restart, and has a documented, physically rehearsed
C003 RAM rescue path with an explicit partition-restoration verification status.
Kernel replacement and `switch_root` are outside this completion definition.
