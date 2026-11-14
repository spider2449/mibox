# Stock platform and Rust init handoff

## Scope and evidence

Live follow-up results are now in `docs/mibox-runtime-console-watchdog.md`:
current console/memory state and kernel watchdog-disable logging are captured,
and init's ordinary-process path has run on the device. Hardware PID1 boot
and USB ACM console testing remain outstanding.

All analysis below is offline against verified backups. No custom boot image
has been generated, flashed or started. The A32 reference parser was copied
unchanged from `F:/coding/otherPrj/amazing-a32-os/scripts/a32_formats.py` into
`scripts/stock_formats.py`; only its bounded FDT reader is used here. The source
repository was not modified. `scripts/inspect-stock-platform.py` reproduces the
inventory under `artifacts/platform/2026-11-13/`.

## Confirmed stock DTB facts

- 11414-byte FDT v17, 66 nodes; compatible `AMLOGIC,8726_MX`.
- Cortex-A9 CPU nodes and vendor `amlogic,aml_uart` nodes uart_ao and uart_0.
- uart_ao pinctrl references GPIOAO_0/GPIOAO_1. This identifies SoC pins, not
  physical board pads, signal direction or voltage.
- `/memory` uses vendor fields: phys_offset=0x80000000 and
  linux,total-memory=0x40000000 (1 GiB). It has no standard reg property.
- aml_reserved_start=0x85000000 and aml_reserved_end=0x84000000 occur in that
  order in the original DTB. Do not normalize this into a guessed address range.
  The old vendor kernel's interpretation and other reserve-memory allocations
  must be traced before replacing the kernel or writing a new memory map.
- The interrupt-controller node declares Cortex-A9 GIC register tuples
  (0xc4301000,0x1000) and (0xc4300100,0x100). No new register writes were made.

JSON stores raw property bytes plus optional cell/string representations.
Representation is not a replacement for vendor binding semantics.

## Environment and boot selection

The original env partition's CRC32 matches the first 32768 bytes using the
standard four-byte-CRC plus data layout. The saved environment includes:

```
bootcmd=hdcp prefetch emmc;run storeboot
storeboot=store read boot1 ${loadaddr} 0 800000;bootm;run recovery
loadaddr=0x82000000
bootdelay=1
```

The preboot script invokes switch_bootpart and modify_cmdline, so this static
record is not a full trace of the current boot decision. It is consistent with
boot1 matching the installed recovery script and the running system1 mount.
The saved bootargs contains console=ttyS0,115200n8 and init=/init. Board UART pad
identification and a captured UART boot log are still absent. Header load
addresses differ from the saved loadaddr and cannot be substituted for it.

No live U-Boot console command set, fastboot boot path, bootm validation policy
or restore path has been tested. String scans of the bootloader found no U-Boot
version banner; that absence proves neither secure boot nor lack of U-Boot code.

## Image-tail findings

In both boot and boot1 every byte after the final declared second/FDT section
is zero. There is no separate nonzero trailer in those measured tails. This
does NOT prove an unsigned/unlocked loader or rule out checks elsewhere.

Recovery has 30372 nonzero bytes after its last declared section. These bytes
remain unclassified (including possible old partition content); do not strip
them or classify them as a signature from size alone. Its expected prefix hash
and Android header ID both match independently.

## Minimal init implementation

`src/bin/mibox-init.rs` builds for armv7-unknown-linux-musleabihf, statically
linked with musl. It is a local candidate, NOT a tested replacement init.

- Outside PID1, it only prints the process/kernel report and exits.
- As PID1, it mounts proc, sysfs and devtmpfs, then maintains a child reaper and
  a local /dev/console interface with help, info, uptime and reaptest commands.
- It never mounts eMMC filesystems, formats storage, configures USB/network,
  changes boot variables or automatically reboots. Filesystem setup errors and
  PID1 panics hold the process instead of intentionally exiting.
- A console-open failure retries; this is not a recovery guarantee. Kernel or
  hardware watchdog behavior can still terminate the experiment.

Validation: release cross-build and Rust formatting checks pass. The ordinary
inspection path ran on the actual box. A full-system qemu-system-arm boot using
a verified generic Debian kernel passed all 8 PID1/console/reaper stages; see
docs/mibox-init-qemu.md. Hardware PID1 execution has not been performed, and
generic-kernel QEMU results do not validate every syscall on stock 3.10.33.

## Boot experiment readiness: NOT READY

The local init can be reviewed and compiled. Hardware boot remains gated on:

1. A stable console handoff: USB ACM COM6 packet exchange is confirmed, but
   live switching later showed reset/incomplete restore evidence. Investigate
   retained logs before retrying. UART board pads/voltage remain unverified.
2. Watchdog handoff: the live stock boot logs disable watchdog at about 2 s,
   and boot_monitor does not exist at runtime. Do not copy that stale init
   script path. The exact timer/register state remains unverified.
3. A verified nonpersistent loader path and tested stock recovery procedure.
4. Understanding recovery's unexplained tail before using it as a template.

Keep the stock kernel and DTB unchanged for the first userspace experiment.
Do not copy the A32 MediaTek watchdog, memory map, USB IDs or fastboot workflow.
