# Live console, memory and watchdog evidence

Read-only collection on 2026-11-13 via the existing temporary root command path.
`src/bin/mibox-read-platform.rs` has fixed diagnostic queries; it writes only
scratch text files and does not change sysfs, USB or watchdog settings.
Original captures are in `phone-tools/runtime/2026-11-13/` with hashes recorded
in `artifacts/platform/2026-11-13/runtime-sha256.json`.

## Console and USB

- /proc/consoles lists ttyS0 at 4:64, and /sys/class/tty/console/active is ttyS0.
- The actual kernel command line has console=ttyS0,115200n8 and init=/init.
- /dev/console is 5:1 and /dev/ttyS0 is 4:64. Physical UART pads and voltage
  remain unverified; the DT pin names alone do not identify a board connector.
- USB functions currently reads `ffs`, with f_ffs/aliases=`adb`.
- f_acm exists but instances is 0; /dev/ttyGS0 is 248:0. A node existing does
  not mean an ACM interface is enumerated on Windows.
- Kernel symbols include acm_function_init/bind_config/unbind_config/cleanup,
  but their addresses were hidden (all zero) even through this root context.

No USB reconfiguration or serial I/O was performed. The existing init candidate
uses /dev/console, so it does not yet provide a reachable USB terminal.

## Watchdog

The live dmesg records these lines during kernel driver initialization:

```
[2.014730] aml_wdt_driver_init,301
[2.017779] ** disable watchdog
```

There is no /dev/watchdog node, /sys/class/boot_monitor, or watchdog-class entry
in the queried running system. The stock init script's boot_monitor/boot_timer
write is therefore not an actionable runtime path here. It must not be copied
as a guessed required operation.

This is evidence that the stock kernel logs a watchdog-disable action before
userspace. It is not a measurement of every hardware timer or proof that a new
boot cannot reset. The exact register/call path remains unverified. The active
panic timeout read from /proc/sys/kernel/panic is 20 seconds; the custom init
does not change it.

## Actual memory map

Live /proc/iomem reports inclusive ranges:

| Range | Classification |
| --- | --- |
| 0x80000000-0x84ffffff | System RAM, 80 MiB |
| 0x85000000-0x8defffff | Video RAM, 143 MiB, includes persistent RAM |
| 0x8df00000-0x9fefffff | System RAM, 288 MiB |
| 0xa0000000-0xbfffffff | System RAM, 512 MiB |

The boot log independently reports 1 GiB installed, 880 MiB usable RAM banks,
and a 1 MiB firmware reservation at the end of the first 512 MiB. This runtime
map is more informative than interpreting reversed vendor DT reserve endpoints
as a standard range. Keep stock allocation behavior for the initial userspace
port; no replacement memory map has been constructed.

## Stock kernel container

`scripts/inspect-stock-kernel.py` initially found no gzip stream. Inspection of
the actual leading header then identified legacy uImage magic 0x27051956 and
compression field 3 (LZMA), as defined in
[U-Boot image.h](https://raw.githubusercontent.com/u-boot/u-boot/master/include/image.h).

The header CRC32 and compressed-payload CRC32 both match. Payload is 3897647
bytes; LZMA decompresses to 11878528 bytes. The uImage load/entry addresses are
both 0x80008000. These inner header addresses differ from the outer Android
header and must not be conflated.

The expanded kernel contains matching vendor watchdog log strings and the same
build date/banner seen in live dmesg. It is stored locally as
`phone-tools/extracted/2026-11-13/boot1/kernel-expanded.bin`; metadata is in
`artifacts/platform/2026-11-13/kernel-inspection.json`. CRC checks establish
container consistency, not bootloader acceptance or authenticity by signature.

## Init validation on the actual box

The ARMv7 static `mibox-init` binary ran as an ordinary shell process and printed
MIBOX_INIT_INSPECT_ONLY with remote exit 0. Evidence:
`artifacts/platform/2026-11-13/init-inspect-device.txt`.
That path makes no mounts; real PID1 setup and console handling still require
a separate boot test. The Mi Box was not rebooted or flashed during collection.
