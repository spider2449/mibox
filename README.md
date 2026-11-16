# MiBOX1S custom Linux bring-up

Target: Xiaomi MDZ-06-AA / casablanca, Amlogic Meson6, ARMv7.
First milestone: retain the device's stock kernel and develop custom userspace.

P0 [custom-system ADB rescue and automatic return to
the USB loader](docs/plans/2026-11-15-custom-system-rescue.md) is **READY** (2026-11-16);
see the [rescue procedure](docs/mibox-rescue-procedure.md). The installed
preboot USB window makes every restart pass C003. Custom system -> C003 ->
custom RAM boot and host-attached cold entry have both passed without Android.
PID1 now restarts on early faults (panic, USB setup failure or a 60 s setup
deadline). All three fault images physically returned to C003 by themselves
(12.4 s, 12.4 s and 72.4 s), and the fail-safe image boots normally. A cold
start with the PC USB unplugged returned to Android (one owner observation).
A kernel panic (PID1 exit) also restarts back to C003 in 35.6 s (`kernel.panic=20`).
Still open: the `usb_burner_reboot`
fallback. C003 bulk OUT transfer is now repaired: `rescue-boot.ps1 -Bulk` loads and boots
the 8 MiB image in 23 s instead of ~22 min ([evidence](docs/mibox-usb-loader-protocol.md)). This takes
precedence over further feature work and default power-on installation.

The Rust init has booted as PID1 on the actual Mi Box through a fully verified
temporary RAM image, retaining the stock kernel and DTB. Custom userspace and
authenticated USB ADB work; the extended Rust toolbox also passes physical
device checks. See [RAM boot evidence](docs/mibox-ram-boot-success.md) and
[live toolbox results](docs/mibox-live-toolbox.md). A newer RAM candidate also
passed [software restart back to Android](docs/mibox-software-return.md) on the
physical box. A separately built [Meson6 container development kernel](docs/mibox-container-kernel.md)
has now passed physical RAM boot, namespace/veth/bridge/seccomp and cgroup-v1
diagnostics, and software return to Android. Docker 24.0.9 has also passed a
[physical offline container test](docs/mibox-docker-runtime.md) using VFS and
cgroup v1 in RAM. Persistent engine services, container networking and
installation as the default power-on system remain unverified.

The separate [console, SSH and apk workflow](docs/mibox-console-ssh.md) adds
Alpine ARMv7 userspace and a host launcher for persistent software/configuration
in a dedicated data-directory chroot. See its linked evidence for the current
physical validation status; Linux power-on installation is a separate milestone.

For the A32-style host-controlled workflow, use
`powershell -NoProfile -File scripts/ram-boot.ps1 -Action RoundTrip` from
completed stock Android. This automates ADB loader entry, pinned RAM upload
and readback, custom boot checks and software return to Android. `-Action Boot`
leaves custom userspace running; the default `-Action Check` validates locally
without device access. See [automation and evidence](docs/mibox-automated-ram-boot.md).

## Build the read-only probe

Requires Rust with the `armv7-unknown-linux-musleabihf` target installed.

```powershell
cargo build --release
```

The target uses static musl and bundled rust-lld, following the owner's
`amazing-a32-os` project. No crate dependencies are needed.

## Run under stock Android via USB

This copies an executable to `/data/local/tmp` and changes its mode. The program
only reads procfs/sysfs; it does not mount, format, reboot or access raw flash.
It is not a PID1 implementation and must not be packaged as `/init`.

```powershell
$adb = '.\phone-tools\platform-tools\adb.exe'
& $adb -s 248243005297 push target/armv7-unknown-linux-musleabihf/release/mibox-probe /data/local/tmp/mibox-probe
& $adb -s 248243005297 shell 'chmod 755 /data/local/tmp/mibox-probe && /data/local/tmp/mibox-probe'
```

`MIBOX_PROBE_OK` means the program completed. Individual inaccessible files are
reported as unavailable; this marker does not imply every capability is present.
Missing root permissions are expected. A success as an Android shell process
does not establish independent boot, PID1 or every Rust syscall's compatibility.

## QEMU PID1 test

The custom init passed all 8 console/reaper test stages under a generic Debian
ARM kernel. See [reproduction and limits](docs/mibox-init-qemu.md). This test
creates a QEMU-only initramfs and does not flash the box.

## Evidence and planning

- [Docker container runtime reference, kernel audit and blockers](docs/mibox-docker-runtime.md)
- [Meson6 container kernel builds and RAM experiment](docs/mibox-container-kernel.md)
- [Bring-up plan](docs/plans/2026-11-13-mibox-linux-bringup.md)
- [A32 reuse map](docs/amazing-a32-reference.md)
- [Hardware findings](docs/mibox-linux-findings.md)
- [Boot-image evidence](docs/mibox-boot-image-evidence.md)
- [OTA investigation and partition geometry](docs/mibox-ota-investigation.md)
- [Confirmed temporary root access](docs/mibox-root-access.md)
- [Verified stock partition backups and boot layout](docs/mibox-stock-images.md)
- [Stock platform and minimal Rust init readiness](docs/mibox-platform-handoff.md)
- [Live console, memory and watchdog evidence](docs/mibox-runtime-console-watchdog.md)
- [QEMU PID1 validation](docs/mibox-init-qemu.md)
- [USB ACM packet results and unresolved reset](docs/mibox-usb-acm-evidence.md)
- [Stock ADB menu reset policy](docs/mibox-adb-reset-policy.md)
- [Reboot-verified persistent USB ADB](docs/mibox-persistent-usb-adb.md)
- [Latest hardware boot readiness](docs/mibox-boot-readiness-2026-11-14.md)
- [Custom userspace tested on the actual box](docs/mibox-custom-userspace.md)
- [Recovered kernel config and software boot/update analysis](docs/mibox-software-boot-analysis.md)
- [Verified system/system1 partition snapshots](docs/mibox-system-backups.md)
- [Offline stock USB console candidate](docs/mibox-stock-usb-console-candidate.md)
- [Stock ADB console and custom userspace: QEMU 11/11 proof](docs/mibox-adb-console-qemu.md)
- [First locally built boot candidate and readiness](docs/mibox-boot-candidate.md)
- [Physical custom PID1/userspace RAM boot: PASS](docs/mibox-ram-boot-success.md)
- [Live Rust toolbox and RAM self-test](docs/mibox-live-toolbox.md)
- [Read-only health snapshot and local ARM validation](docs/mibox-userspace-health.md)
- [Updated health custom Linux RAM boot and Android return: physical PASS](docs/mibox-health-ram-roundtrip.md)
- [Ethernet, HDMI and audio bring-up](docs/mibox-network-hdmi-audio.md)
- [RAM framebuffer capture: live color-bar screenshot verified](docs/mibox-framebuffer-capture.md)
- [Read-only runtime follow-up](docs/mibox-runtime-followup.md)
- [Software return interface and QEMU restart validation](docs/mibox-software-return.md)
- [Local backup revalidation and restoration gates](docs/mibox-restoration-readiness.md)
- [Stock recovery input mapping and interface evidence](docs/mibox-recovery-interface.md)
- [Exact stock UCL bootloader and rescue handler analysis](docs/mibox-bootloader-ucl.md)
- [Exact reboot-mode mapping and USB-loader entry branches](docs/mibox-loader-entry-branches.md)
- [Stage-one shared boot information and source selection](docs/mibox-stage1-boot-info.md)
- [Physical Android remote-input inventory](docs/mibox-remote-input.md)
- [IR decoder comparison and sourced recovery-entry candidate](docs/mibox-ir-decoder-comparison.md)
- [Current recovery pending-state checks and cold-entry observer](docs/mibox-recovery-cold-entry-preflight.md)
- [Touch-remote cold-entry attempt and confirmed Android checkpoint](docs/mibox-cold-recovery-attempt.md)
- `artifacts/probe/2026-11-13/`: actual USB execution output and build provenance.
- `scripts/Collect-MiboxInfo.ps1`: read-only inventory, not a firmware backup.
