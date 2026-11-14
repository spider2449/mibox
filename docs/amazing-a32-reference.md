# Reusing amazing-a32-os for MiBOX1S

Inspected 2026-11-13 at `F:/coding/otherPrj/amazing-a32-os`.
Reference checkout HEAD: `d38214cb674c06b89cca3e5376e1aa30ca2035a7`.
Findings below come from the current files, not a new test of the A32 phone.
The reference repository was not modified.

## Recommended first target

Use the Mi Box's own Linux 3.10.33 kernel with a small custom Rust initramfs.
This follows A32's stock-kernel/custom-userspace architecture and avoids requiring
a complete upstream board port before testing userspace. It still requires a
matching Mi Box boot image and a proven way to boot a modified ramdisk. Neither
has been obtained yet. Root is one possible route to backup access, not proof
that a custom image can boot.

Keep a later self-compiled kernel as a separate milestone. The reference's
MediaTek kernel-4.9 work cannot supply an Amlogic board port.

## Reuse map

| Reference files | Reuse on Mi Box | Required changes or evidence |
| --- | --- | --- |
| `.cargo/config.toml` | ARMv7 static-musl target and rust-lld pattern | Execute a minimal static probe on the actual 3.10 kernel before assuming Rust/libc syscall compatibility |
| `src/main.rs`, `src/probe.rs` | Non-PID1 read-only report entry, separate PID1 path | Start with a Mi Box-only probe; do not include A32 PID1 hardware actions |
| `src/pid1.rs` | Mount setup, child reaping, logging and service structure | Rewrite board setup, partition discovery and failure recovery; no assumed fastboot reboot target |
| `src/shell.rs`, `terminal.rs` | Console structure | Establish actual UART/USB transport first |
| `src/usb.rs` | General gadget abstraction | A32 writes MediaTek VID/PID and assumes ACM/RNDIS; Mi Box currently uses FunctionFS for ADB. Probe capabilities before any gadget writes |
| `src/wifi.rs`, `dhcp.rs`, `sntp.rs` | Pure parsers and protocol logic | Mi Box loaded `dhd`; phone module controls, firmware paths and vendor executables need replacement. Networking remains optional |
| `src/watchdog.rs` | Service heartbeat idea | Do not reuse MediaTek watchdog assumptions or reboot policy |
| `src/fb.rs`, `display.rs`, `input.rs` | Generic drawing/input parsing concepts | Probe HDMI framebuffer layout and input events; omit phone touch/power behavior |
| `src/alpine.rs` | Optional later userspace expansion | Re-evaluate kernel support, disk usage and mount paths; no data formatting at first boot |
| `tools/bootimg` | Offline Android-v0 inspection and cpio tooling, conditionally | First establish Mi Box magic/header/page layout/trailer; parser rejects a separate DT section. Repacking drops the existing trailer and is not evidence of bootloader acceptance |
| `scripts/build-image.sh` | Extract-stock-kernel + custom-initramfs build sequence | Replace A32 OTA/template/output paths; image generation waits for verified Mi Box format |
| `scripts/ram-boot.ps1` | Test-loop structure only | It invokes fastboot boot; Mi Box fastboot/RAM boot is UNKNOWN |
| `scripts/backup-partitions.ps1` | Hash-checked backup procedure | Discover Mi Box partitions and read permissions; do not copy A32 names or offsets |

## Revised milestones

1. Build a small static ARMv7 userspace probe and run it as an ordinary process
   under stock Android using USB ADB. Success establishes only userspace ABI
   compatibility, not PID1, root or independent boot support.
2. Obtain matching Mi Box boot/recovery images; record hashes and parse offline.
3. Establish a recoverable boot path and inspect UART boot logs if needed.
4. Implement minimal Mi Box PID1: proc/sys/dev setup, child reaping and a verified
   local console; defer networking, UI, storage writes and automatic restarts.
5. Package the stock Mi Box kernel with that initramfs only after format and
   loader acceptance requirements are understood; prefer nonpersistent boot.
6. Port optional services one at a time; subsequently investigate kernel builds.

No A32 kernel, DTB, boot image, partition number, load address or vendor register
is a Mi Box hardware fact. Build success is not boot success.
