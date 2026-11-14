# Read-only userspace runtime snapshot

The toolbox now provides `/bin/mibox health`; PID1's console provides `health`.
Both share `src/runtime_health.rs` and report boot ID, uptime in seconds, PID1
name, root filesystem type, and MemTotal/MemFree/MemAvailable in KiB.
`MIBOX_HEALTH_SNAPSHOT_V1` identifies the output format, not a passing verdict.

Every input read is limited to 65536 bytes. Missing, unreadable, over-limit or
non-UTF8 input produces UNKNOWN fields. Invalid boot IDs, duplicate memory
fields, malformed memory units/values and ambiguous root mounts are rejected.
On the stock 3.10.33 kernel, an absent MemAvailable remains UNKNOWN; no estimate
is substituted. Individual counters are kernel-reported values, not a proof
that memory accounting is accurate. The reads are sequential, not atomic.

The command only opens procfs files for reading. It does not configure network,
USB, mounts, watchdogs or persistent storage, and does not request a reboot.
The PID1 console serves it directly without starting a child process.

Reproduce the local parser tests and generic ARM console validation:

```powershell
cargo fmt --check
cargo build --release --bin mibox-init --bin mibox-userland
wsl -d Ubuntu-24.04 -- sh -lc 'cd /mnt/f/coding/otherPrj/mibox && rustc --test src/runtime_health.rs -o target/userspace-health/parser-tests && target/userspace-health/parser-tests'
wsl -d Ubuntu-24.04 -- python3 /mnt/f/coding/otherPrj/mibox/scripts/build-qemu-initramfs.py
wsl -d Ubuntu-24.04 -- python3 /mnt/f/coding/otherPrj/mibox/scripts/test-init-qemu.py --evidence /mnt/f/coding/otherPrj/mibox/artifacts/userspace-health/2026-11-14/qemu-baseline
```

Add `--request-usb-acm` and a different evidence path for the absent-gadget
fallback check. This uses the retained generic Debian ARM kernel and QEMU-only
initramfs, with no persistent disk or network attached.

Evidence is under [artifacts/userspace-health/2026-11-14](../artifacts/userspace-health/2026-11-14/):
parser output, build/source hashes, initramfs provenance and separate QEMU logs.
Five parser/read-bound tests passed; baseline and absent-gadget fallback each
passed 11/11 QEMU stages. ARM release builds and formatting passed. Both
executables are little-endian ARM ELF32 without DYNAMIC or INTERP program
headers, as recorded in `elf-validation.json`.
No replacement kernel, Mi Box boot image, new hardware boot or hardware health
claim is part of this change. The physical-tested Restart image and the RAM
orchestrator's pinned hashes remain the existing baseline; these rebuilt
binaries require a separately versioned candidate and physical verification
before claiming device support.

## Standalone toolbox through stock adbd

The QEMU-only `mibox-adb-probe` now opens separate legacy ADB streams for
`/bin/mibox info` and `/bin/mibox health`. The latter uses the stock shell to
append the command's actual exit status, since legacy ADB stream closure alone
does not convey a successful command exit. The probe requires exit 0, exactly
the expected snapshot fields, the current guest boot ID, PID1 init, rootfs,
and numeric uptime/memory counters on the generic kernel.

Baseline and dedicated-key authenticated tests each passed **12/12 stages**.
The authenticated run rejected an invalid signature before accepting the
authorized test challenge response. The missing-test-flag guard also passed
**12/12**, refusing probe setup and leaving standalone-ADB-health verification
false. The successful shell transcripts include UID/EUID 2000 on the preceding
info stream. No physical USB transport was used: adbd listens only on guest
loopback in a diskless QEMU guest with no external network interface.

[Baseline result](../artifacts/userspace-adb-health/2026-11-14/baseline/result.json),
[authenticated result](../artifacts/userspace-adb-health/2026-11-14/authenticated/result.json),
[guard result](../artifacts/userspace-adb-health/2026-11-14/guard/result.json)
and separate initramfs/build provenance are retained.

Reproduce after building `mibox-init`, `mibox-userland` and `mibox-adb-probe`:

```sh
python3 scripts/build-qemu-initramfs.py --with-stock-adb
python3 scripts/test-init-qemu.py --test-stock-adb --evidence artifacts/userspace-adb-health/2026-11-14/baseline
python3 scripts/test-init-qemu.py --test-stock-adb-guard --evidence artifacts/userspace-adb-health/2026-11-14/guard
python3 scripts/build-qemu-initramfs.py --with-stock-adb-auth
python3 scripts/test-init-qemu.py --test-stock-adb-auth --evidence artifacts/userspace-adb-health/2026-11-14/authenticated
```

Run Python/QEMU commands in WSL at the repository root. The probe continues
to require both the explicit test boot flag and QEMU virt device-tree identity,
and refuses an Android USB gadget. It is not a device deployment tool.

## Stock kernel prerequisites

The locally extracted stock config was rehashed against its pinned SHA256
`bd2a94b6aa84afda30661c3a4b41f9759fcc6734ee32daf8335882ba6b43c918`.
All 15 audited prerequisites are explicitly enabled: ARM/AEABI/VFP, ELF,
procfs/sysfs, initrd/gzip, devtmpfs/tmpfs, futex/epoll, Unix/IPv4 sockets and
Unix98 PTYs. [The complete check](../artifacts/userspace-adb-health/2026-11-14/stock-config-contract.json)
retains each setting. Kexec and namespaces remain explicitly disabled.

Configuration support is necessary evidence, not proof that the new binary's
syscalls, procfs layout or stock-kernel behavior pass. QEMU uses Linux 6.12;
the old-kernel missing-MemAvailable path is covered by parser fixtures only.
The next hardware milestone is a separately hashed toolbox deployment into
RAM and readback/execution verification on the existing stock-kernel runtime;
that has not been performed for this revision. A replacement kernel still
requires matching board/source/memory/driver evidence and is not claimed ready.

## Physical stock-kernel validation

The follow-up on 2026-11-14 found the box running stock Android, rather than
the earlier custom RAM runtime. `/tmp` was a tmpfs and shell directory guards
passed, but ADB sync upload of the new 511820-byte toolbox failed with exit 1
and remote Permission denied. SELinux was Enforcing; the precise cause is
UNKNOWN. The attempted binary SHA256 was
`2e4f1dfd8f28c0bf52323a9e65abf314e1e1705505414cc7cc25fcdf99128512`.

Inspection then found /tmp mode 0765: shell's group has write permission but
lacks directory search permission. No security setting was changed. The
failed /tmp destination's existence remains UNKNOWN due to denied traversal.

Using the project's established `/data/local/tmp` scratch directory instead,
the toolbox was uploaded to a fresh content-addressed path and pulled back.
Source and readback SHA256 matched. The actual health command passed with
explicit shell exit 0 on ARMv7 Linux 3.10.33 as UID2000. It reported PID1 init,
rootfs root, MemTotal 877072 KiB, and MemFree 70296 KiB at observation.
Actual /proc/meminfo lacks MemAvailable; the command correctly returned UNKNOWN.
Boot ID remained `ecdad7fb-31d0-4e02-adb5-863bdf0529d5`.

The separate info command exited 1 because stock Android lacks /etc/os-release.
The exact temporary executable on /data was removed and absence verified.
This involved temporary persistent-storage scratch writes, not RAM-only
deployment or installation. No reboot, root escalation, mounts or security
changes occurred. Standalone health compatibility is now physically verified;
The later [updated RAM candidate round trip](mibox-health-ram-roundtrip.md)
also physically passed: updated PID1/toolbox hashes, health execution in the
custom RAM system, and normal return to completed Android were verified.
See [device plan](plans/2026-11-14-health-device.md),
[result](../artifacts/userspace-health-device/2026-11-14/result.json), and
[provenance](../artifacts/userspace-health-device/2026-11-14/provenance.json).
