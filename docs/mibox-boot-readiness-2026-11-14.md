# Custom Linux boot readiness, 2026-11-14

Latest result: the exact candidate has now passed a temporary physical RAM boot,
with custom Rust PID1/userspace, authenticated USB ADB and full image readback.
See [physical boot evidence](mibox-ram-boot-success.md). Persistent installation
and a newly built kernel remain unverified. The following assessment records
the earlier pre-test state.

Historical pre-test decision: NOT READY for a custom hardware boot. Keep the stock boot/recovery
partitions. The persistent USB ADB V3 fix is installed and reboot-verified;
this follow-up made no bootloader, partition, USB-mode or reboot changes.

Later software-only follow-up recovered the embedded kernel configuration,
confirming CONFIG_KEXEC=n and CONFIG_NAMESPACES=n. It also ran custom userspace
on the actual box and expanded QEMU PID1 checks to 10/10. The earlier runtime
kexec uncertainty below is superseded by docs/mibox-software-boot-analysis.md.

## Recovery tail narrowed down

`scripts/inspect-recovery-tail.py` validates recovery's independently pinned
6794846-byte prefix SHA1 e94825710e912cc47f09dee1be17fb43d1fc564d before analysis.
The final declared section ends at 6794390. All 456 bytes between those offsets
are zero. All 30372 nonzero trailing bytes lie AFTER the update script's target
length. Nonzero regions, joining gaps up to 64 bytes, are:

| Start | Exclusive end | Finding |
| --- | --- | --- |
| 6794846 | 6818606 | Unclassified bytes; no long exact prefix match to the other checked partition backups |
| 6819840 | 6831877 | Contains a fully parsed FDT starting at 6819840 |

The FDT has declared size 12038, 71 nodes and SHA256
4afef3786b9c1c726771aa737a5cb875ace4cf9c067c8dc54d021f3641a94002.
It differs from the declared 11414-byte recovery DTB. Its final byte is zero,
so the nonzero region's exclusive end precedes the FDT's exclusive end by one.
These findings are consistent with residual content from a different image,
but do not prove the origin of every byte or bootloader acceptance policy.
Do not call the complete tail a signature, or strip/repack it on this evidence.

Reproduce under WSL:

```sh
python3 scripts/inspect-recovery-tail.py --output artifacts/platform/2026-11-14/recovery-tail.json
python3 scripts/inspect-stock-recovery.py --output artifacts/platform/2026-11-14/recovery-config
```

The scripts read existing backups only. The cpio extractor accepts a fixed
allowlist of regular files, verifies bounds/trailer, records hashes and never
executes extracted scripts.

## Stock recovery is not a demonstrated USB rescue path

Recovery default.prop has ro.debuggable=0, ro.secure=1 and ro.adb.secure=1.
Its init.rc leaves adbd disabled and USB gadget enable is only set to 1 in the
ro.debuggable=1 trigger (or service.adb.root trigger). Thus init configuration
alone does not establish an automatically reachable recovery ADB shell. The
recovery executable may have additional behavior; that remains UNKNOWN.

Extracted restore_system.sh mounts /dev/block/backup read-only, mounts
/dev/block/system, deletes that system directory's contents and copies backup
contents into it. It does not implement restoration of active system1 or boot
images. It was inspected as text and NEVER executed. Recovery fstab lists both
system and system1 separately; this is not proof of a safe automatic fallback.

## Runtime boot alternatives

Read-only temporary-root diagnostic `mibox-read-platform bootpath` found:

- /proc/self/ns exposes only mnt, so isolated PID-namespace PID1 execution has
  not been established. Do not run the mount-performing init path in Android.
- /sys/kernel/kexec_loaded and kexec_crash_loaded are absent.
- The filtered kallsyms output contains only weak `W sys_kexec_load`, with
  hidden zero address, and no matched machine_kexec/kernel_kexec implementation.
  A weak syscall symbol alone does not prove kexec support. No load/unload or
  reboot syscall was attempted; kexec remains UNCONFIRMED.

Evidence: artifacts/platform/2026-11-14/runtime-bootpath.txt.

## Historical pre-test gates and current disposition

1. Establish an observable software boot path within the owner's no-hardware-
   modification constraint. UART is an optional diagnostic, not a mandatory
   requirement; do not require board photographs, disassembly or soldering.
2. Establish a verified nonpersistent loader command and a usable return path.
3. Validate console and watchdog handoff under the stock kernel before replacing
   Android PID1. Keep live USB ACM switching disabled pending its unresolved reset.

The later physical test established the software RAM boot path, full image
readback, custom PID1 and FunctionFS console for the exact candidate. Owner
power recovery returned to Android before that test. Software-only return from
the later custom candidate passed one physical test with a changed Android
boot ID, original fingerprint and boot_completed=1. See
[software return evidence](mibox-software-return.md). Long-duration watchdog
behavior remains unverified.
Live USB ACM switching remains disabled. See the physical boot evidence above.

Generic ARM QEMU PID1 tests remain userspace evidence. The physical RAM boot
is PASS for the recorded candidate; persistent installation is NOT READY.
