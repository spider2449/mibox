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

## Bulk framing restored from reference source (2026-11-15)

The failed 2026-11-14 BulkTest is now interpretable against exact reference
source (codesnake/uboot-amlogic c0b0b8cc9bd5901ced2e929ea87b99fae52d528c,
`usb_pcd.c`). Bulk mode is not a replacement for the EP0 command; it adds a
bulk data stage after the EP0 command:

1. EP0 SETUP 0x40/0x12 (`AM_REQ_RD_LARGE_MEM`), wValue=block length,
   wIndex=block count, wLength=16.
2. EP0 OUT data stage, 16 bytes: `[0..3]` address, `[4..7]` total data length.
3. `do_vendor_out_complete` takes address/length from that data, recomputes
   `bulk_len = DWC_BLK_LEN(len)` (blocks of at most 0x1000 bytes) and
   `bulk_num = DWC_BLK_NUM(len)`, ignoring the SETUP wValue/wIndex, then arms
   the bulk endpoint: reads use bulk IN 0x81, writes bulk OUT 0x02. Bulk MPS
   is 512 (high-speed descriptor). `xferNeedReply` stays 0 for RD/WR_LARGE_MEM,
   so there is no per-block handshake.

Implications: the previous single-bulk-probe failure cannot distinguish a
framing mismatch (for example a 16-byte payload sent on bulk OUT instead of
the EP0 OUT data stage), missing bulk endpoint enable timing, or an
Xiaomi-build difference from this reference. The probe wedged the loader and
identify stopped responding, so bulk image actions remain disabled and any
new probe must stay single-shot, read-only and bounded.

`scripts/Probe-MiboxUsbLoaderBulk.ps1` implements that bounded probe: identify
gate (00-08-00-10), control-channel reference read of 0x82000000 (64 bytes),
one RD_LARGE_MEM 0x12 bulk IN attempt with a 2 second timeout, byte compare,
a post-probe identify on a fresh handle to record loader survival, and one
evidence directory under `artifacts/usb-loader-protocol/bulk-*/`. No retry,
no write, no boot command; a wedged result requires owner power recovery and
must not be retried. Results are not recorded yet; the device has not been
driven through this probe. If a 64-byte BULK_MATCH is observed, the next step
is a separately designed bounded 4 KiB chunk test, never an immediate full
image transfer.

## Bulk probe results (2026-11-15): bulk path unusable on this build

Two single-shot read-only probes ran after owner-coordinated loader entry:

- Cold power, host attached, exposed C003 directly, identify 00-08-00-10. This
  is the first physical cold-start evidence for the installed preboot USB
  window; it reproduced on two cold starts the same day.
- Attempt 2 used the exact restored three-stage framing. The EP0 SETUP plus
  16-byte RD_LARGE_MEM command was accepted (16 bytes transferred), then the
  bulk IN read failed immediately with native 87 (ERROR_INVALID_PARAMETER,
  host-side) and the post-probe identify on a fresh handle got no answer:
  the loader wedged, matching the 2026-11-14 outcome pattern.
- Before attempt 2, `scripts/Probe-MiboxUsbConfigDescriptor.ps1` dumped the
  raw configuration descriptor (GET_DESCRIPTOR(CONFIG) only): 32 bytes,
  bulk IN 0x81 and bulk OUT 0x02, both bulk attr 0x02 with MPS 512, exactly
  matching the reference descriptor. An earlier MaxPacketSize=0 reading from
  `WinUsb_QueryPipe` was a host struct-layout error, not a device property;
  the descriptor itself is correct.

Verdict: with correct framing and correct endpoints, the bulk data stage
still fails and wedges the loader. Bulk image actions are permanently
disabled for this build; the 64-byte EP0 control channel is the only
established data path. Each bulk attempt costs an owner power cycle, so no
further bulk probing is planned.

Also recorded: a recovery-mode `adb reboot usb_burner_reboot` and even plain
`adb reboot` returned -1, in-shell `/sbin/reboot` was denied, and after that
denial the device still rebooted into a black screen requiring a power
cycle. Recovery shell reboot is unverified and uncontrolled; not a loader
entry route. The working entry today was owner cold power with the host
attached, which lands directly in C003.

## Bulk OUT repaired (2026-11-16): full 8 MiB load in 23 seconds

**This supersedes the "bulk path unusable" verdict above.** Two host-side errors
caused the 2026-11-15 failure; it was never evidence about the device:

- The probe passed the `WinUsb_QueryPipe` *index* (0) as the PipeID to
  `WinUsb_SetPipePolicy`/`WinUsb_ReadPipe`. WinUSB requires the endpoint address
  (0x81/0x02), so it rejected the call with native 87 before any IN token was
  sent.
- The `WINUSB_PIPE_INFORMATION` layout was wrong (`int PipeType; byte PipeId;
  ushort MaximumPacketSize; byte Interval`), so it reported MPS 0. Now it
  reports `mps512` for both endpoints.

Why the loader then stopped answering: in the reference `dwc_pcd.c`, bulk IN uses
TX FIFO 0 (`txfnum = 0`), the non-periodic FIFO it shares with EP0. When a bulk IN
request is armed but never drained, it blocks later EP0 IN data, including the
identify reply. The 2026-11-14 bulk IN read (correct endpoint 0x81) also timed
out, so **bulk IN is still unused**. Bulk OUT goes through the RX FIFO path that
EP0 OUT already uses successfully.

Physical results (the box entered C003 through a normal custom-system restart):

| Step | Evidence | Result |
| --- | --- | --- |
| `Probe-MiboxUsbLoaderBulk.ps1 -Direction Write -Bytes 64` | `artifacts/usb-loader-protocol/bulk-20261116-214742/` | `BULK_WRITE_VERIFIED`, 0.24 ms, EP0 verify, original restored, post-identify 00-08-00-10 |
| same, `-Bytes 4096` | `artifacts/usb-loader-protocol/bulk-20261116-214751/` | `BULK_WRITE_VERIFIED`, 0.51 ms, loader survived |
| `rescue-boot.ps1 -Action WaitAndBoot -Candidate FailSafe -Bulk` | `artifacts/rescue-boot/20261116-214805-314/` | PASS: 23 s end to end, 8.2 s upload |

Bulk upload protocol (`Test-MiboxLoaderRam.ps1 -Bulk`, UploadCandidate/UploadAndBoot):

1. For each 4096-byte block: EP0 0x40/0x11, wValue=4096, wIndex=1, 16-byte LE
   address/length, then `WinUsb_WritePipe(0x02)`. The guard limits writes to
   0x82000000..0x82800000.
2. Sampled EP0 readback: the first 64 bytes of every 64 KiB plus the final 64
   bytes (129 reads) must match.
3. Write a 64-byte sentinel at 0x82800000, then send the fixed TPL command
   `crc32 0x82000000 0x800000 0x82800000` (0x30, index 1). TPL status 0x31 must
   read `success`. The CRC is stored little-endian in the first 4 bytes, and
   bytes 4..63 must still hold the sentinel. Observed `3dcd0e9e` matched the
   host CRC32 of the pinned FailSafe image.
4. `bootm 0x82000000`, then the existing custom-runtime observer and PID1/tool
   hash pulls.

`RamBootValidation.ps1` accepts a bulk transfer record only with
`VerificationMethod=BulkOutCrc32`, the pinned source SHA256, a matching crc32,
a `success` status and at least 129 samples. A bulk upload has no full
readback SHA256, so `VerifiedSha256` is null. Without `-Bulk`, the 64-byte
control path is unchanged. `BootCandidate` (readback only) still uses control.
