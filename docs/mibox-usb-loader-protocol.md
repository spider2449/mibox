# Live USB loader evidence

Latest: full 8 MiB control-channel upload/readback and 64-byte TPL bootm
command succeeded in booting custom PID1/userspace on the actual device.
See [physical RAM boot proof](mibox-ram-boot-success.md). The diagnostics below
retain the earlier failures; bulk image actions remain disabled.

The software reboot argument `usb_burner_reboot` exposes USB 1B8E:C003.
The owner installed WinUSB for the actual device: oem40.inf, problem code 0,
interface GUID d925a7f0-61a4-4018-bcd3-f3e5225f3532.

`scripts/Probe-MiboxUsbLoader.ps1 -Identify -ReadBootBuffer` verifies the standard
device descriptor before vendor requests. Actual identify response: 00-08-00-10.
The four version/stage bytes do not establish secure-boot state.

The optional fixed RAM read uses vendor IN request 0x02, wValue 0x8200,
wIndex 0, length 64. Address 0x82000000 comes from the backed-up device
environment's loadaddr. Two live reads succeeded with identical data.
Retained response and PnP snapshot: artifacts/usb-loader-protocol/2026-11-14/.

Protocol reference: codesnake/uboot-amlogic commit
c0b0b8cc9bd5901ced2e929ea87b99fae52d528c, drivers/usb/gadget/v2_burning/
v2_usb_tool/usb_pcd.c and optimus_transform.c. This is reference source,
not a proven exact Xiaomi build. READ_MEM copies into a 512-byte buffer;
the host deliberately requests only 64 bytes. TPL command index 1 dispatches
optimus_working; the reference routes bootm through run_command and has a
separate reset branch. See the actual reset attempt below.

Subsequent bounded RAM test wrote 64 bytes (byte i XOR 0xa5) at 0x82000000,
verified every byte, restored the original 64 bytes and verified restoration.
Evidence: ram-selftest.json in the same artifact directory.

TPL reset used a zero-padded 512-byte command, request 0x30, index 1. The
control transfer completed, but C003 remained present through observation and
subsequent identify timed out. Thus software return is FAILED for this attempt;
the owner power-cycled and Android/ADB returned (boot ID
8728abd4-158d-4d17-9ff3-18caf398cc83). reset-attempt.json and
reset-observations.json retain the transport result and observed state.

The reference optimus_reset sets the normal reboot mode then calls reset_cpu;
it has no saveenv call. That source path is not evidence that the physical box
executed it. platform.h defines flush_cpu_cache as an empty macro, so a readback
match alone does not prove instruction-cache coherency for executing RAM code.

scripts/Test-MiboxLoaderRam.ps1 restricts writes to 0x82000000..0x82800000,
requires the pinned 8 MiB candidate hash before USB access for image actions,
and compares every readback byte plus full SHA256. BootCandidate requires a
fresh full RAM verification before its fixed bootm command. These image actions
use 64-byte transfers after the first 512-byte READ_MEM attempt timed out.
The loader still responded to identify and a 64-byte read after that timeout;
the read showed the candidate's ANDROID! header in RAM. A complete image
transfer is being evaluated separately. There is no arbitrary command input.

The 64-byte control upload verified 786432 bytes before the host process was
stopped to test the source-described bulk path. The full image SHA256 was
not established. upload-progress-64.txt retains the progress output.

BulkTest queried the actual endpoints (bulk IN 0x81 and OUT 0x02), then sent
RD_LARGE_MEM 0x12 with a 16-byte address/length payload for a 64-byte RAM read.
The bulk read failed with Win32 121, and subsequent identify failed. The
pattern-write stage was not reached. This diagnostic does not establish
compatibility with the reference bulk implementation. Bulk image actions
are disabled; owner power recovery was requested again.

At that diagnostic checkpoint RAM transfer had begun, with no flash write or
boot command yet sent. The later full control transfer and physical boot
success are documented in mibox-ram-boot-success.md.
