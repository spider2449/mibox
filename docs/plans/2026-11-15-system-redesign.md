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
| Bulk OUT repaired (2026-11-16) | Native 87 was a host PipeID bug. Bulk OUT + device crc32 loads 8 MiB in 23 s end to end; bulk IN still unused (`docs/mibox-usb-loader-protocol.md`) |
| Host-attached cold rescue works | Cold power -> C003 -> pinned RAM console without Android; host-disconnected deadline expiry/continuation remains unobserved (`docs/mibox-independent-rescue.md`) |

Measured partition layout: bootloader 2 MiB, reserved 2 MiB, env 4 MiB,
logo 4 MiB, recovery 8 MiB, boot 8 MiB, boot1 8 MiB, system 512 MiB,
system1 512 MiB, cache 192 MiB, data 2.5 GiB.
Source: `artifacts/partitions/layout.json`. Historical verified backups include
env (2026-11-15), boot/boot1 (2026-11-13), and system/system1 (2026-11-14).
Recheck their exact paths, sizes and hashes before using them for restoration.

## Storage plan (owner decision 2026-11-16: Android need not be kept)

Android is no longer a retained system. This frees space but does not by itself
authorize any delete, format or partition write; each step below needs its own
backup, evidence and explicit owner approval at execution time.

Until Phase C installs a custom flash boot, Android's boot/system partitions are
still the host-disconnected cold-start target and the ADB loader-entry path used
by `ram-boot.ps1` and the software-return tests. Removing them earlier turns a
host-disconnected cold start into a failed boot that only C003 rescue recovers.
Partition order therefore follows dependencies, not size:

S1. [x] Inventory data (from pinned RAM console, data mounted read-only where
   possible): usage per top-level directory, Android app/media/cache trees,
   the Alpine tree and its free space. Current free space is about 438 MiB.
   Done 2026-11-17, mounted `ro,noload` (no journal replay), then unmounted:
   `artifacts/console-root/20261117-192144-s1-data-inventory/`,
   `20261117-192210-s1-detail/`. ext4 2270600 KiB, 1855024 used, 399192
   available (82%); inodes 7%. Usage in KiB:

   | Tree | KiB | Class |
   | --- | --- | --- |
   | app (apks) | 426140 | Android, reclaim |
   | dalvik-cache | 375908 | Android, regenerable |
   | data (app data) | 342708 | Android, reclaim |
   | app-lib | 262164 | Android, reclaim |
   | media (0/shafa downloads 98628, Android 56300) | 217068 | Android, reclaim |
   | spdif.mkv, autovideo.mov, test.mkv | 54508 | factory test media, reclaim |
   | log, anr, tombstones, dontpanic, diagnosis | 17072 | Android logs, reclaim |
   | mibox-console (Alpine; usr 47500, tmp 9900) | 64000 | keep (A2 backup first) |
   | local/tmp (earlier project tools, logs, boot-backup dirs) | 48052 | keep until compared with PC backups |
   | system, misc, property, ssh | ~3300 | keep while Android boot is the cold-start/ADB path |

   About 1.65 GiB is Android payload. Constraint for S3: Android's ADB
   loader-entry path depends on `misc/adb`, `property/persist.sys.usb.config`
   and `system`; keep those until Phase C. A later Android boot rebuilds
   dalvik-cache for system apps (slow first boot) and may recreate logs.
S2. [x] Back up the Alpine tree, configuration and keys to the PC (also A2).
   Android userdata has no backup; the owner has accepted its loss.
   Done 2026-11-17 (data `ro,noload`, unmounted after): `scripts/backup-data-trees.sh`
   streamed `mibox-console` (incl. rootfs `/etc`, `/root`, SSH keys) and
   `local/tmp` to `phone-tools/backup/2026-11-17-s2/`: `mibox-console.tar`
   `5d655f74…`, `local-tmp.tar` `915b5960…`. `verify-tree-backup.py` PASS:
   3557 entries (type, mode, owner, size) and 2435 regular files by SHA256
   against a device-side listing; one socket in local/tmp is not archivable.
   Evidence `artifacts/storage/s2-20261117/backup-verification.json`. Restore is
   untested; A2 still needs a restore rehearsal before the tree is changed.
S3. [x] Reclaim Android files on data by deleting directories, not formatting.
   Android may regenerate some files if it boots again before Phase C.
   Done 2026-11-17 with owner approval of the listed paths
   (`scripts/device/s3-reclaim-android.sh`, evidence
   `artifacts/console-root/20261117-192815-s3-reclaim-android/`). Deleted app,
   app-lib, dalvik-cache, media, log, anr, tombstones, dontpanic, diagnosis,
   duokancache, the three test videos and data/* except
   `com.android.providers.settings` (adb_enabled). Kept system, misc, property,
   ssh, local/tmp, mibox-console. Free space 399192 -> 2098616 KiB (5% used),
   no ext4/I/O errors, unmounted after. Re-hash of the kept trees matches S2
   (2435 files, `…-s3-post-hashes/`). Android cold boot after this deletion
   and its ADB loader-entry path are not yet re-verified.
   Note: the S1-S3 device scripts used `test a && test b` chains, which
   `set -e` enforces only for the last test. The S3 output shows every guarded
   path existed, so the run was unaffected; the scripts now use `;`.
S4. [~] Budgets and guards: keep a data free-space floor (initially the
   launcher's 64 MiB; revise from S1) enforced before apk installs and by PID1;
   bound logs (size cap/rotation); keep Docker test storage in RAM until data
   space is measured, since VFS copies every layer.
   2026-11-17, host-launched console: floor set to 256 MiB (about 11% of
   data; covers Android rebuilding its system-app dalvik-cache if it boots
   before Phase C). The persistence helper refuses initial tree creation
   below it, reports `MIBOX_DATA_FREE_KIB`, and installs an `apk` guard that
   refuses add/upgrade/fix/update below the floor (del/cache clean pass).
   `scripts/test-apk-guard.py` PASS (12 cases); on device the guard hash
   matches the source, is first on PATH, passes real commands at 2098604 KiB
   free, and a high-floor copy refused `add` with exit 75
   (`artifacts/console-ssh/launcher-20261117-193201/s4-guard-*.txt`).
   Logs: no persistent writer exists today (Alpine `var/log` empty, no syslog
   in the chroot); RAM PID1 logs stay in RAM. Docker test config already uses
   `data-root /run/mibox-docker-test` (RAM) with json-file logs capped at
   1m x 2 (`scripts/prepare-mibox-docker.py`).
   Fixes 2026-11-17: the guard now reads free space with `stat -f` (statfs);
   BusyBox `df` fails inside the chroot, which made the guard refuse
   `apk add coreutils` on a fresh tree. Known gap: the guard is first on PATH
   only for login shells; a non-interactive `ssh host apk …` gets dropbear's
   default PATH and runs `/sbin/apk` unguarded. Candidate fix: an apk
   pre-commit hook in `/etc/apk/commit_hooks.d/`, to be verified.
   Closed 2026-11-17: verified on the box that a failing pre-commit hook makes
   apk abort (exit 99, nothing installed; `…/20261117-201503-apk-hook-probe/`).
   The helper now also installs `/etc/apk/commit_hooks.d/mibox-floor.sh`
   (`cc122d54…`): pre-commit fails below the floor unless the owner creates
   `/etc/apk/mibox-allow-below-floor` (apk runs hooks without transaction
   details or environment, so `del` below the floor needs that file). Host test
   17 cases PASS. On Slim, a high-floor copy aborted a non-interactive
   `/sbin/apk add tree`; with the real hook, add and del work
   (`…/20261117-202202-slim-physical-boot3-hook/`).
   Open, moved to Phase B: PID1 enforcement of the floor once it mounts data
   (B1/B4 "full" case), and a size-capped log rotation (e.g. BusyBox
   `syslogd -s 1024 -b 2`) when B3 starts any persistent logging service.
S5. [x] Boot image budget: record kernel, DTB and per-component initramfs
   sizes and slack for every candidate (A4/A5).
   Done 2026-11-17, offline: `scripts/report-boot-budget.py` ->
   `artifacts/boot-budget/2026-11-17/boot-budget.json` (18 candidates, all
   page 2048, tails zero). Stock kernel 3897711 bytes (Docker/kernel
   candidates 4107835), DTB in `second` 11414. With the stock kernel the
   ramdisk capacity is 4474880 bytes. Console family slack 32768-45056; the
   pinned FailSafe ramdisk is 4441336 (gzip level already equal to gzip -9).
   FailSafe gzip -9 estimates: libcrypto 1.50 MB, busybox 0.50, musl 0.38,
   libssl 0.34, init 0.29, mibox 0.25, mibox-hardware 0.25, system/bin/sh
   0.15, dropbear 0.13, CA certs 0.11, adbd 0.10; OpenSSL + apk + skarnet
   total about 2.1 MB and are needed only for package management, which
   belongs in Alpine. Single-stream projections from the FailSafe ramdisk
   (method reproduces it to 4 bytes): init/mibox/adbd/busybox/musl/etc
   1547200 bytes (slack 2926592); + system/bin/sh 1702694; + mibox-hardware
   1796171; + RAM dropbear 2111606 (slack 2361344). The 1.5 MiB A4 target is
   met only by the minimal set; fbhandoff (~209 KB) and splash (~9 KB) fit in
   every projection. Projections are not built or booted images.
S6. [ ] After Phase C passes: decide reuse of system/system1 (1 GiB total) and
   cache (192 MiB), e.g. as separate ext4 for containers, or a clean reformat
   of data. Requires verified backups, a revised partition-scope rule and
   physical restart evidence. Not part of Phases A–C.

## Phase A — prepare the small RAM supervisor and persistent userspace

A1. [x] Inventory the current pinned Console initramfs and existing persistent
   Alpine tree. Record compressed/uncompressed sizes, required binaries and
   libraries, installed packages, free data space and current service startup.
   Separate what early PID1/recovery needs from what can run in Alpine.
   Done 2026-11-17 from S1/S2/S5 evidence. FailSafe ramdisk 4441336 gzip /
   7737428 raw, 106 files, 336 symlinks (per-component sizes in
   `artifacts/boot-budget/2026-11-17/boot-budget.json`). Alpine tree 64000
   KiB, 3352 entries, world: alpine-baselayout, alpine-keys, alpine-release,
   apk-tools, busybox, coreutils, curl, dropbear, htop, less, libc-utils,
   nano, python3. Data free 2098616 KiB after S3.
   Current startup: PID1 `/init` -> USB ADB (`/sbin/adbd`, `/adb_keys`) ->
   `/sbin/mibox-console-start` (devpts, static IPv4 192.168.1.222, dropbear
   with a host key generated in RAM each boot, optional fbhandoff/splash).
   Persistence is mounted later by the host launcher, which uploads
   `mibox-persistent-console`.
   Classification (dynamic: only busybox and dropbear, both need musl):

   | Component | Place | Reason |
   | --- | --- | --- |
   | `/init`, `/bin/mibox` (static) | RAM | PID1, restart/return control |
   | `/sbin/adbd` (static), `/adb_keys`, `etc/mibox-usb-adb.enabled` | RAM | authenticated recovery transport |
   | `bin/busybox` + `lib/ld-musl-armhf.so.1` | RAM | recovery shell, mount, ip, mknod, tar |
   | `system/bin/sh` (static stock) | RAM unless adbd is shown to work with busybox `sh` | adbd's shell path |
   | network script + `etc/mibox-network-static` | RAM | static IPv4 before Alpine |
   | `mibox-persistent-console` (data/chroot helper) | RAM, built in | B1 replaces host upload |
   | `sbin/mibox-fbhandoff`, splash | RAM, optional (A5) | early display |
   | `sbin/mibox-hardware` | Alpine (or omit) | on-demand diagnostics, not boot |
   | dropbear, dropbearkey, libz, libutmps, skarnet | Alpine | B3; persistent host key replaces per-boot key |
   | apk, libapk, OpenSSL, CA certs, scanelf, apk keys | Alpine | package management only (~2.1 MB gzip) |

   The A3 minimal set projects to 1547200 bytes gzip (S5).
A2. [ ] Preserve `/mnt/mibox-data/mibox-console/rootfs` as the canonical Alpine
   tree. Before changing it, create and verify a recoverable backup of that tree,
   configuration and keys. Do not duplicate the whole distribution, format data,
   or overwrite unrelated Android files. Device identity gates remain 179:11,
   5168640 sectors and the existing ext4 filesystem.
   2026-11-17: backup from S2 (verified). PC restore rehearsal
   `scripts/rehearse-tree-restore.sh` PASS
   (`artifacts/storage/a2-restore-rehearsal-20261117-193843/`): extracted in
   a user namespace on WSL ext4; all 2435 files match by SHA256 and every
   entry matches type, mode, size and (for the Alpine tree, all 0:0) owner.
   Expected differences: 5 character devices under the leftover
   `rootfs/tmp/mibox-audio-test/dev` (mknod not permitted) and one socket.
   Limits: `local/tmp` Android owners (1000/2000) are checked only in the
   tar (S2), not after extraction; symlink targets are compared only by
   length; mtimes are not compared; no restore has been run on the device.
   Device restore procedure, untested: from the RAM console with persistence
   stopped, mount data, rename `mibox-console` to
   `mibox-console.replaced-<date>` (never delete), stream
   `tar -xpf - --numeric-owner` of `mibox-console.tar` into the data root,
   unmount, then rerun the S2 `list`/`hashes` modes and diff with S2.
A3. [~] Build a separate slim initramfs with custom PID1, authenticated USB ADB,
   required BusyBox applets/libraries, fixed-IP network setup, the data/chroot
   lifecycle helper and a usable RAM recovery shell. Keep SSH in RAM only if
   needed for recovery; otherwise start it in Alpine. Do not add DHCP by default:
   the current verified network uses owner-confirmed static IPv4.
   2026-11-17, owner choices: keep `system/bin/sh`; SSH runs from Alpine.
   `scripts/build-slim-rootfs.py` derives the slim rootfs from the pinned
   FailSafe rootfs (`266bdba6…`), keeping init `a24de13a…`, `/bin/mibox`
   `e275d1d0…`, adbd, system/bin/sh, busybox (304 applet links), musl, ADB
   keys and network/identity files unchanged; removes apk/OpenSSL/CA certs,
   RAM dropbear and libraries, and mibox-hardware (103 entries); adds
   `assets/rootfs/mibox-slim-start` and the built-in persistence helper.
   Rootfs 1715554 bytes gzip (`8a6a6004…`); local candidate
   `target/mibox-boot-candidate-slim` `4445921b…`, end 5629952, slack
   2758656, tail zero (`artifacts/slim-candidate/2026-11-17/`). Not uploaded,
   not booted, not flashed; it would also need a new pin in the RAM loaders.
   QEMU `scripts/test-slim-qemu.py` PASS, 24 checks
   (`artifacts/slim-qemu/20261117-195425/`), data disk built from the S2
   backup: two boots with strict persistent host key, session inside Alpine,
   data mounted, file persistence, stop from the caller's own SSH session,
   SSH gone and `e2fsck -fn` clean after stop; no disk and empty ext4 stay
   RAM-only with no SSH and create nothing. Launcher-mode helper regression
   (`test-console-qemu.py --persistent`, disk raised to 512 MiB for the S4
   floor) PASS (`artifacts/slim-qemu/regression-helper-launcher-mode-20261117/`).
   Open before any physical boot: see B5 note (restart with data mounted).
A3a. [x] Before A4 or any new boot-image packaging, revalidate the complete
   hash-checked boot/boot1 backups and their parsed section bounds/tails.
   Start from `docs/mibox-stock-images.md`, its verified backup manifest, and
   `docs/mibox-platform-handoff.md` (Image-tail findings): measured boot/boot1
   tails were entirely zero. Record reproducible offsets and classification;
   refuse packaging if a target-image tail layer remains UNKNOWN. Recovery's
   unclassified tail is outside this plan's unchanged partition scope.
   A32's `docs/a32-boot-image-format.md` supplies methodology, not MiBOX facts.
   Zero tails and C003 bootm acceptance do not establish flash-path acceptance
   or exclude checks elsewhere; retain that distinction in C1/C4/C5.
   Done 2026-11-17: `scripts/verify-boot-backups.py` (independent parser) PASS
   (`artifacts/boot-evidence/2026-11-17/a3a-boot-backups.json`). boot.img
   `ff4fa440…` and boot1.img `06d9eb7e…` match the 2026-11-13 manifest; page
   2048, image IDs recompute; kernels are legacy uImages with valid header and
   data CRCs and no bytes after the data; `second` is an exact 11414-byte FDT;
   ramdisks gunzip to newc with a trailer. Every byte outside the sections is
   ZERO: header slack 608-2048, each section's page padding, and the tail
   (boot from 4431872, boot1 from 4433920, to 8388608). No layer is UNKNOWN.
   The Slim (`87daa0d3…`) and FailSafe candidates pass the same checks and
   carry boot1's exact kernel, DTB and header addresses. Read-only device
   hashes of partitions 179:6 (boot) and 179:7 (boot1) equal the backups
   (`artifacts/console-root/20261117-202552-a3a-boot-partition-hashes/`).
   Finding for C1: boot and boot1 hold different kernels with the same DTB
   and ramdisk size. boot's uImage is dated 2016-07-27; boot1's 2017-02-20
   07:47:46 UTC. Android on 2026-11-13 reported `#1 SMP PREEMPT Mon Feb 20
   15:47:21 CST 2017` (07:47:21 UTC), i.e. that cold Android boot ran boot1's
   kernel. One observation; it does not establish current env selection.
A4. [ ] After A3a passes, preserve stock kernel/uImage, DTB, cmdline and load
   addresses. Recalculate
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
Answered 2026-11-17 from the extracted config: only `CONFIG_RD_GZIP=y`;
RD_LZMA, RD_XZ, RD_LZO and RD_BZIP2 are not set. Keep gzip; no experiment.
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
   No format, automatic additional filesystem repair or rootfs replacement.
   Deliberate deviation from A32, recorded: A32 runs `e2fsck -p` before mount;
   normal ext4 journal replay during mount is allowed here and can write to
   data. Capture mount results and kernel errors. A failed mount or detected
   filesystem error enters RAM recovery without starting Alpine or attempting
   additional automatic repair. Document future policy changes with evidence.
B2. [x] Define rootfs readiness and integrity checks. Pin expected immutable
   startup files or a versioned baseline manifest in the initramfs; do not trust
   a manifest solely because it sits beside its payload. Treat package upgrades,
   `/etc`, `/root`, logs and keys as explicitly mutable state with a controlled
   baseline-update procedure. Preserve existing packages and owner data.
   Done 2026-11-17. Readiness (boot mode): tree marker, os-release ID, host
   key 0:600, dropbear executable, authorized_keys present; no tree package
   tool runs as root at boot (the `apk info` check is launcher-mode only).
   Integrity: `/etc/mibox-alpine-baseline` in the slim initramfs (sha
   `3f6db0e5…`, built by `build-slim-rootfs.py` from the committed S2 device
   hashes, cross-checked against the hash-pinned S2 archive) pins dropbear,
   musl loader, libz, libutmps, libskarnet, busybox and 6 links. Owner policy
   (2026-11-17): report, still start SSH. Result in `/run/mibox-alpine-integrity`
   and kmsg `MIBOX_ALPINE_INTEGRITY=MATCH|MISMATCH <paths>`. Baseline update:
   rebuild Slim from a new verified tree backup and re-pin. QEMU: MATCH on the
   S2 tree, MISMATCH naming the altered libz with SSH still up. Physical Slim
   `dd1e6756…`: MATCH (`artifacts/rescue-boot/20261117-213138-728/`).
B3. [x] Start and supervise the selected Alpine services from the outer PID1.
   Reuse or migrate existing SSH host keys and owner authorized keys with correct
   permissions; verify that server identity survives a restart without the host
   launcher re-pinning a newly generated key. Establish time synchronization
   independent of the host; report unsynchronized time until verified.
   B3 progress 2026-11-17: SSH host key and authorized keys are the
   persistent Alpine ones (verified physically, B7). Time: the RTC only counts
   since cold power-on (read 3942 s, 1970), so the slim start script syncs by
   NTP (busybox ntpd, pool.ntp.org + time.cloudflare.com; UDP 123 verified
   from the owner LAN) in the background right after the network, with
   back-off, resync every 6 h, state in `/run/mibox-time-state`
   (UNSYNCHRONIZED -> `SYNCED <utc>`); the RTC is never written. QEMU 31
   checks PASS (`artifacts/slim-qemu/20261117-201911/`; one earlier run
   crashed after boot 2's mount check with no evidence retained, two
   following runs passed). Physical Slim `87daa0d3…`
   (`artifacts/rescue-boot/20261117-202114-211/`): synced 12.9 s after
   kernel start. Files the helper writes before the first sync carry 1970
   mtimes (cosmetic). Still open: supervision is a shell restart loop in the
   start script (reparented to PID1's reaper), not PID1 itself.
   Closed the same day: PID1 (init `4d6dae1f…`) supervises Alpine dropbear.
   The start script only writes `/run/mibox-alpine-ready`; a PID1 thread
   starts `/usr/sbin/dropbear` via chroot to the fixed tree path (env cleared),
   learns its exit from the reaper (no waitpid race; spawn under the reaper
   lock), restarts with 5..60 s back-off and stops on `/run/mibox-alpine.stop`
   (set first by the helper's stop). QEMU slim 35 checks PASS incl. killed
   listener restarted (`artifacts/slim-qemu/20261117-212251/`); PID1 regression
   PASS (`artifacts/pid1-supervisor-regression/`); the kpanic fault case lost
   its console marker in 2 of 3 runs (panic output overran it), fixed with a
   500 ms drain pause in fault builds only, then 5/5 PASS. Physical: listener
   181 killed, SSH back after ~6 s, new listener 437 with parent 1
   (`artifacts/console-root/20261117-213307-b3-supervision/`).
B3a. [ ] Optional experiment, disabled by default and not a startup gate:
   extracted MiBOX config has CONFIG_SWAP=y and CONFIG_ZRAM=y; verify the live
   device/control interface, supported compression and setup/teardown behavior
   before enabling swap. A32 uses half of total RAM, not half of free RAM;
   choose a MiBOX size from measured memory use and bounded pressure tests.
   Use an available validated swap-header tool; custom header generation is
   unnecessary unless separately justified and verified. Record swap usage,
   physical zram allocation, responsiveness, OOM and shutdown behavior; a
   compressible workload alone does not establish practical capacity or benefit.
B4. [ ] If data is absent, wrong, full, invalid, or fails to mount/start, keep
   PID1, authenticated USB ADB and a RAM shell available. Do not start partial
   services or overwrite the failed tree. Record failure and allow explicit
   recovery. C003 RAM rescue is available on the next bootloader entry, not as a
   USB service inside the running kernel.
B1/B4 progress 2026-11-17 (QEMU only, see A3): the slim start script runs
   `mibox-persistent-console start --boot` after network setup. Boot mode
   never creates a tree, checks host key/dropbear/authorized_keys, publishes
   the host public key to RAM for USB authentication, undoes its mounts on any
   failure (`MIBOX_PERSISTENT_BOOT_FAILED`), and otherwise leaves PID1 + USB
   ADB only (`MIBOX_PERSISTENT_UNAVAILABLE`). Alpine dropbear runs under a
   shell restart loop, not yet PID1 supervision (B3).
B5 gap 2026-11-17: `stop` now kills every process rooted in the tree and
   unmounts, but only root can run it, and with the slim image root is only
   reachable over Alpine SSH. PID1's RESTART/CHECK refuse while data is
   mounted (`readiness()` rejects any non-RAM mount, even for CHECK), and USB
   ADB is uid 2000. If SSH fails with data mounted, the only exit is a power
   cycle (C003 -> FailSafe; ext4 journal replay next mount). Next: a PID1
   `PERSIST-STOP <boot_id>` request (uid 0/2000) that runs the built-in
   helper `stop` as a bounded child, then the existing RESTART.
   Implemented the same day: `ram_control` splits `identity()` (root PID1,
   custom OS, platform guard) from `ram_only_mounts()`; PERSIST-STOP needs
   only identity and runs the root-owned, non-group/other-writable
   `/sbin/mibox-persistent-console stop` via PID1 (90 s bound, reaper lock,
   8 KiB output each stream). CHECK/RESTART/LOADER keep requiring RAM-only
   mounts. Client: `mibox persist-stop --boot-id ID`. Slim image now uses
   release init `b1f3b654…` and mibox `c7f2b1b1…`; candidate `8d7849d9…` (superseded the same day by `87daa0d3…` with the apk hook and NTP)
   (ramdisk 1717239, slack 2756608), pinned as `Slim` in
   `rescue-boot.ps1`/`Test-MiboxLoaderRam.ps1` (local Check PASS, no USB).
   QEMU `test-slim-qemu.py` PASS 27 checks
   (`artifacts/slim-qemu/20261117-200129/`): as uid 2000 with data mounted,
   CHECK and RESTART are refused and a stale-boot-ID PERSIST-STOP is refused;
   PERSIST-STOP then RESTART from a RAM-rooted uid-2000 shell stops
   persistence, restarts the guest and leaves a clean filesystem. PID1
   regression on the new source PASS (`artifacts/pid1-persist-stop-regression/`:
   console 11/11, restart incl. uid 2000 and LOADER, fail-safe normal/panic/
   usb/hang/kpanic). Physical validation pending (B7).
B5. [~] Extend the restart lifecycle for mounted data. Stop services and sessions,
   synchronize state, unmount chroot binds and data, then request normal restart.
   Existing restart control refuses block filesystem mounts; preserve that guard
   until teardown is verified. A busy/unmount failure must be reported and must
   prevent the normal controlled restart, rather than forcing through it.
B6. [ ] Host/QEMU validation: actual slim rootfs startup and supervision; fixture
   data tree success, absent/invalid data, partial mount cleanup, unexpected
   identity, key persistence, and clean/busy shutdown. Generic QEMU validates
   userspace behavior, not stock Meson6 kernel or bootloader compatibility.
B7 progress 2026-11-17 (owner-approved RAM boots, Slim `8d7849d9…`, bulk):
   boot 1 `artifacts/rescue-boot/20261117-200923-128/` and boot 2
   `…/20261117-201116-028/` both `CustomBootVerified` with init `b1f3b654…`
   and mibox `c7f2b1b1…`. Data mounted automatically ~7 s after kernel start
   (`MIBOX_PERSISTENT_BOOT_READY free_kib=2098608`), Alpine dropbear started;
   SSH with strict host key = S2 persistent key `…6A91`, session root in the
   Alpine tree, packages and the stat-based apk guard (`45842180…`) present
   (`artifacts/console-root/20261117-201051-slim-physical-boot1/`). B5 over
   USB ADB as uid 2000: CHECK refused while mounted, `persist-stop` ->
   `MIBOX_PERSIST_STOP_EXIT=0`, data unmounted, CHECK ready, RESTART -> C003 ->
   Slim again (`…/b5-adb.txt`). Boot 2: no journal recovery on mount, boot-1
   sentinel retained, same host key (`…-slim-physical-boot2/`). Box left
   running Slim with data mounted. Not yet covered here: owner-observed HDMI
   (no display files in Slim), time sync, and a cold power-on of Slim.
   Update 2026-11-17: time sync closed under B3. Cold power-on of Slim
   `dd1e6756…` (owner power-cycle, PC attached, after `persist-stop` left only
   RAM mounts; `artifacts/b7-cold-power-on/2026-11-17/pre-poweroff.txt`): the
   host polled 160 times with no C003 before the power cycle, then C003 ->
   Slim `CustomBootVerified` (`artifacts/rescue-boot/20261117-213538-197/`).
   Data mounted with no journal recovery, `MIBOX_ALPINE_INTEGRITY=MATCH`, time
   synced 14 s after kernel start, PID1-supervised SSH with the persistent key,
   previous boot's sentinel retained (`artifacts/console-root/*-b7-cold-slim/`).
   Remaining B7 item: owner-observed HDMI, only if display files (A5) are added.
B7. [ ] Physical RAM validation: separately pin the new 8 MiB image, upload and
   fully read back/hash before boot. Verify boot ID, OS/PID1/tool hashes,
   automatic chroot/services, SSH key authentication, static network, persistent
   file I/O and owner-observed HDMI when display additions are included.
   Perform controlled restart and another verified RAM boot; confirm saved
   state and SSH host identity survive without manual persistence activation.
B8. [ ] Optional RAM-boot power-cut rehearsal; not a prerequisite for Phase C.
   Before an owner-coordinated cut, verify host-side backups of valuable shared
   data (including Android files), the Alpine tree/keys, and an offline recovery
   procedure usable from pinned RAM rescue with data unmounted. Test-directory
   isolation does not isolate the shared filesystem from power-loss effects.
   Limit writes to a dedicated test directory with an explicit byte cap and
   free-space reserve derived from measured capacity; never fill the partition.
   Rewrite bounded scratch files while appending/syncing numbered counter lines;
   retain host-side evidence of completed syncs before the owner cuts power.
   After re-entry and RAM boot, record mount/journal/kernel results and compare
   known-good files and completed synced lines. Require successful mount and no
   unresolved filesystem errors; journal replay messages are not mandatory on
   every cut. One result establishes only that tested power-loss scenario.

After B, userspace startup is automatic and persistent. Cold starts still need
RAM upload until Phase C passes. No system/system1 redundancy write is included:
`system1` is an existing Android system partition, not a free spare rootfs slot.

## Phase C — permanent custom boot and independent rescue

C1. [x] Establish actual cold-start boot selection from the current env and
   exact-loader flow, including dynamic `switch_bootpart`/cmdline behavior.
   Static `storeboot=store read boot1 ...` alone is insufficient. Record the
   selected partition and evidence; do not assume boot1 or change slot/env.
   Done 2026-11-17 offline, see `docs/mibox-boot-selection.md`: the installed
   env (device hash `6142e34f…`) has `bootsystem=1`, `upgrade_step=0`, no
   `resetenv`; `switch_bootpart` (0x8f870b7c) maps bootsystem 0->boot,
   1->boot1, other->unchanged by rewriting `storeboot`, which then reads
   boot1. Matches the 2026-11-13 Android kernel (boot1's build). Selection
   flips to boot if `bootsystem=0`, on plain `defenv` (`upgrade_step=1`) or
   an env reset to built-in defaults (which also drop the USB window).
   `storeargs` and `modify_cmdline` save the env on normal boots. If `bootm`
   returns, `run recovery` boots stock recovery. Target for C3: boot1 (179:7).
C2. [x] Before boot-partition writes, verify host-disconnected continuation on
   the existing boot setup with owner-controlled power and observation. Measure
   elapsed startup time and result. `update 10000` is not a proven 10-second
   duration. Retain the installed env hash and host-attached cold C003 evidence.
   Done 2026-11-17 (owner-run): persistence stopped over USB ADB first, only
   RAM/virtual mounts left (`artifacts/c2-cold-start/2026-11-17/pre-poweroff.txt`;
   env hash `6142e34f…` read the same day). Owner unplugged USB from the PC
   and power-cycled. Owner observation: first (bootloader) logo about 30 s
   after power-on, then the Android boot logo, still there after ~8 min. So
   without a host the `update 10000` window expired and the bootloader
   continued to boot1; the kernel and Android init ran, with `/system` from
   system1 (consistent with `bootsystem=1`, C1). Measured: power-on to first
   logo ~30 s by the owner's stopwatch; window length itself not isolated.
   Android itself did not finish booting: after USB was reconnected, Android
   ADB (authorized, stock fingerprint) showed `system_server` restarting every
   ~6 s with "Failed to find provider info for settings" -> NPE in
   `showBootMessage` (`android-logcat.txt`, `android-data-state.txt`); a
   consequence of the S3 reclaim (owner accepted Android loss), not of the
   boot path. Android ADB `reboot` with the host attached reached C003 and Slim
   loaded and verified (`artifacts/rescue-boot/20261117-210018-730/`): data
   mounted cleanly, time synced, same host key, tree intact; Android's run
   used ~40 MiB of data. Consequence: the Android ADB loader-entry path still
   works while adbd runs, but a host-disconnected cold start now ends in
   Android's boot loop, not a usable Android.
C3. [x] Prepare a concrete write AND restoration procedure for the proven target:
   exact partition identity/size, current full backup and hashes, original backup,
   pinned new candidate, write/flush/full-readback tools and independent second
   collection. Restoration must be executable from the known-good RAM rescue
   OS without relying on the installed boot image or Alpine tree. Validate host
   safeguards and the read-only recovery prerequisites before requesting approval.
   2026-11-17: procedure `docs/mibox-boot1-install.md`. Tool
   `mibox-partwrite` (`e4750d65…`, static armv7; `src/partwrite.rs` with its own
   SHA-256): only boot1 (179:7, 16384 sectors, writable, unmounted) on Meson6,
   or QEMU `vdb` with `mibox.test_partwrite=1`; image 8 MiB with named hash;
   refuses unless boot1's current hash is named; O_SYNC|O_EXCL write, fsync,
   BLKFLSBUF, full re-read. Restore = same tool with the boot1 backup
   (`06d9eb7e…`). Host unit tests 7 PASS; QEMU block-device rehearsal 15 PASS
   (`artifacts/partwrite-qemu/20261117-210900/`) incl. Slim write, independent
   busybox re-hash and restore. Real box read-only dry run PASS from Slim
   (`artifacts/console-root/20261117-211020-c3-dryrun-prep/`): 179:7, current
   `06d9eb7e…`, wrong hash and target `boot` refused. Restore needs only root
   SSH to a RAM root (FailSafe's RAM dropbear, no data). Dry run from FailSafe
   with no ext4 mounted and no persistent shell PASS (`artifacts/console-root/20261117-211336-c3-failsafe-prep/`):
   restore direction reports AlreadyInstalled (boot1 still stock), install
   direction DryRunVerified, no node left behind.
   C4 gate status: B2 and B3 closed 2026-11-17; the rest of B7 (cold
   power-on of Slim, HDMI if display files are added) is open.
C4. [x] Once mandatory B gates (B1-B7, excluding optional B3a) pass and C1-C3
   evidence is ready, obtain explicit owner
   authorization for the specific boot-partition write. Install the identical
   full-size bytes that passed physical RAM validation. Perform one bounded
   write, fsync/cache flush, full 8 MiB readback and independent second collection;
   require exact hash matches before any restart. No automatic retry.
   Done 2026-11-17 with explicit owner authorization ("Write Slim to boot1
   now"). From Slim in RAM: tool `e4750d65…` and image `dd1e6756…` uploaded
   and re-hashed; dry run verified current boot1 `06d9eb7e…`; write
   `MIBOX_PARTWRITE_READBACK_VERIFIED=dd1e6756…`; independent busybox re-hash
   after drop_caches: boot1 179:7 `dd1e6756…`, boot 179:6 unchanged
   `ff4fa440…` (`artifacts/console-root/20261117-214011-c4-boot1-write/`).
   Env, bootloader, boot, recovery, system* and data were not written.
   Restore: `docs/mibox-boot1-install.md` (expect-current `dd1e6756…`).
C5. [x] Owner-observed cold boot with the USB host disconnected: bootloader
   window continues into the custom system from flash, then PID1 automatically
   activates Alpine and SSH. Verify runtime identity, persistent keys/state and
   measured startup time. Follow with a controlled restart back into the custom
   system and verify a new boot ID. Record no RAM upload or Android dependency.
   Done 2026-11-17 (`artifacts/c5-cold-boot/2026-11-17/`). After `persist-stop`
   left only RAM mounts, the owner unplugged USB from the PC and power-cycled;
   no RAM upload ran (no rescue script, ADB list empty). Observed over the LAN
   only (`scripts/watch-c5-ssh.sh`, strict host key): SSH answered at
   13:43:58 UTC with kernel uptime 10.57 s, boot ID `e3c73b6f…`, stock kernel
   with the bootloader's own cmdline (`androidboot.system=1`), data mounted at
   5.8 s, `MIBOX_ALPINE_INTEGRITY=MATCH`, PID1-supervised dropbear (ppid 1),
   persistent host key `…6A91`, earlier sentinel retained; NTP synced at
   13:43:59. Controlled restart without host (`persist-stop` then
   `reboot-android` from a RAM-rooted shell over SSH, 13:44:38): back on SSH at
   13:45:09 (31 s; kernel uptime 10.18 s, so bootloader + expired window
   ~21 s), new boot ID `f291711f…`, previous boot's sentinel retained, data
   mounted without journal recovery, integrity MATCH. Power-on-to-SSH total
   for the cold start awaits the owner's stopwatch reading. No Android
   dependency: Android's boot partition and system1 were not involved.
C5a. [ ] Separate persistence acceptance after C5 and C6 pass; not a prerequisite
   for installation or basic independent boot. Apply all B8 backup, offline
   recovery, bounded-write and owner-power prerequisites even if B8 was skipped.
   Cut power during test-file writes, then cold start without a host. Verify
   automatic flash startup, successful data mount, no unresolved filesystem
   errors, known-good file integrity and completed synced counter lines.
   Record journal behavior without requiring replay messages on every cut.
   Report power-loss acceptance separately; one pass covers that scenario only.
C6. [x] Rehearse host-attached cold C003 interception with the persistent custom
   image installed, then reload the known-good pinned RAM rescue and verify it
   can identify/read the target and access the restoration material. Never damage
   a partition as a test. This proves pre-kernel interception and RAM reload;
   partition restoration remains NOT VERIFIED until an authorized restoration
   write and its independent readback actually pass. Do not equate this with
   automatic recovery from every kernel/PID1 failure or watchdog hang.
   Done 2026-11-17 (`artifacts/c6-cold-interception/2026-11-17/`). With Slim
   installed on boot1 and persistence stopped (confirmed over USB ADB), the
   owner power-cycled with USB attached: C003 appeared and FailSafe loaded and
   verified (`artifacts/rescue-boot/20261117-214632-555/`). From FailSafe (RAM
   root, no ext4, no persistent shell) boot 179:6 `ff4fa440…` and boot1 179:7
   `dd1e6756…` were read; the uploaded tool and stock backup hashed correctly
   and the restore dry run (stock over Slim) verified; nothing written
   (`artifacts/console-root/20261117-214907-c6-failsafe-rescue/`).
   Finding: a normal restart with the PC attached and no upload stayed at
   C003 for over 10 minutes (no flash boot); C003 remained present. The window
   expires only when no host enumerates the loader (C2/C5). Day-to-day
   unattended flash boots therefore need the USB cable disconnected from the
   PC. The box was then loaded with Slim into RAM from that C003
   (`artifacts/rescue-boot/20261117-215954-136/`). No loader "continue"
   command was sent (unverified).

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

Order: A inventory/backup and A3a image-tail gate -> slim candidate and B lifecycle -> host/QEMU checks
-> B physical RAM/restart checks -> C selection, no-host continuation and recovery
preparation -> owner-authorized installation -> standalone cold boot/restart and
rescue rehearsal. C1-C3 read-only analysis/tool preparation may run before B ends.
Optional B3a/B8 do not block this sequence. C5a persistence acceptance follows
successful standalone boot and C6 rescue rehearsal, with a separate result.

Completion means stock-kernel custom PID1 boots from flash without a host,
automatically starts persistent Alpine and authenticated SSH, preserves state
and server identity across restart, and has a documented, physically rehearsed
C003 RAM rescue path with an explicit partition-restoration verification status.
Kernel replacement and `switch_root` are outside this completion definition.
