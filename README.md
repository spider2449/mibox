# MiBOX1S custom Linux bring-up

Target: Xiaomi MDZ-06-AA / casablanca, Amlogic Meson6, ARMv7.
First milestone: retain the device's stock kernel and develop custom userspace.
The Rust init has booted as PID1 on the actual Mi Box through a fully verified
temporary RAM image, retaining the stock kernel and DTB. Custom userspace and
authenticated USB ADB work; the extended Rust toolbox also passes physical
device checks. See [RAM boot evidence](docs/mibox-ram-boot-success.md) and
[live toolbox results](docs/mibox-live-toolbox.md). Persistent installation and
a replacement kernel remain unverified.

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
- `artifacts/probe/2026-11-13/`: actual USB execution output and build provenance.
- `scripts/Collect-MiboxInfo.ps1`: read-only inventory, not a firmware backup.
