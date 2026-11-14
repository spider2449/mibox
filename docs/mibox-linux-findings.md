# MiBOX1S bring-up findings (2026-11-13)

## Local evidence

Complete collection: `artifacts/device-info/20261113-210525-651/`.
The two earlier directories are incomplete collector-development runs.
`sha256.csv` records hashes of the complete collection; this is not a raw backup.

Read-only probes of the first 512 bytes of `/dev/block/boot` and
`/dev/block/recovery` (output discarded to `/dev/null`) both returned
`Permission denied`. No device storage was written.

Boot image format, signature policy, kernel load addresses and RAM boot support
therefore remain unknown. Empty Android lock properties do not prove unlocked
boot. Reading `/sys/class/aml_store/part_table`, `store_device` and `version`
returned no contents in this session, despite readable mode bits.

The device exports vendor UART devices `ttyS0` (uart_ao) and `ttyS1` (uart_0).
These names do not establish board connector pinout or electrical voltage.
Loaded modules include `dhd` and `mali`; no Wi-Fi chip identification was obtained.
`fw_env.config` refers to `/dev/mtd/mtd9`, whereas the running device uses eMMC
block partitions. Treat it as potentially stale; do not use it to write env.

## Development host

WSL distribution Ubuntu-24.04 is available. Probes found gcc, make,
arm-linux-gnueabihf-gcc and qemu-system-arm. `dtc` was not found on PATH.
No kernel, rootfs or flashable image has been built or tested.

## Static Rust probe validation

Built mibox-probe with Rust 1.99.0 for armv7-unknown-linux-musleabihf, using
rust-lld and static musl. The 380200-byte executable was uploaded to
`/data/local/tmp/mibox-probe`, chmodded 755, and executed over USB as UID 2000.
It exited successfully and printed MIBOX_PROBE_OK. A second execution preserved
the output under `artifacts/probe/2026-11-13/device-output.txt`, alongside compiler
provenance and a binary hash. This demonstrates ordinary-process execution and
procfs/sysfs reads on the stock kernel, not independent boot or PID1 capability.

The probe found devtmpfs in /proc/filesystems and ttyGS0 device number 248:0.
UART ttyS0/ttyS1 report 4:64 and 4:65. None of these consoles were opened or
reconfigured, so console operation and USB ACM host enumeration remain untested.

## Source decision

Linux v6.12 contains `arch/arm/boot/dts/amlogic/meson6.dtsi`, describing the SoC's
two Cortex-A9 CPUs and UART clocks. It is a source reference, not a device tree
for this board. Xiaomi's MiBox kernel repository README lists MIBOX3/global
once-o-oss, not casablanca. A matching vendor source tree has not been identified.

References:

- https://raw.githubusercontent.com/torvalds/linux/v6.12/arch/arm/boot/dts/amlogic/meson6.dtsi
- https://github.com/MiCode/MiBox_Kernel_OpenSource
- https://www.linux-meson.com/hardware.html

## Next hardware milestone

Obtain a stock firmware image matching this board for offline analysis, or
capture the bootloader UART console using a board-verified pinout and voltage.
This should establish image packaging and a recoverable boot path before a
casablanca kernel configuration or flash script is produced.
