# Network, HDMI and audio baseline

Latest physical result: **Hardware3 Ethernet and owner-visible HDMI passed**;
ALSA accepted all 144000 PCM frames, but audible output remains UNKNOWN.
The box returned normally to completed stock Android. See the final result
section and `hardware3-candidate/physical-summary.json` for the exact evidence.

Owner setup: wired Ethernet and HDMI connected; Wi-Fi is not configured.
The owner subsequently confirmed that only a monitor is connected. Audible
output cannot be validated with the current equipment.
The initial baseline was collected from completed stock Android on
2026-11-14 at 19:40 Asia/Taipei. It does not validate custom RAM userspace.

Evidence: `artifacts/network-hdmi-audio/20261114-194014-307/`.
Boot ID: `175120b6-cd0a-484c-bd05-a8fb038e8c1d`, Linux 3.10.33,
ADB shell UID2000. Each host process was bounded to 15 seconds and its
complete output and process status retained. Legacy ADB host exit 0 does not
establish success for each shell subcommand; individual errors are retained.

| Function | Physical stock observation | RAM status before this work |
| --- | --- | --- |
| Ethernet | eth0 up, carrier 1, speed 100 Mbps; address 192.168.1.222; gateway 192.168.1.1; gateway ping 3/3, exit 0 | Unverified; prior RAM evidence had eth0 down and no routes |
| Wi-Fi | wlan0 exists, dhd loaded, no IPv4 address | Deferred; owner has not configured Wi-Fi |
| HDMI | HPD 1, display mode 1080p; fb0 virtual size 1280,3240, 32 bits/pixel | Unverified; no framebuffer rendering test |
| Audio | ALSA card AML-DUMMY-CODEC; PCM device 0 and SPDIF device 1; HDMI audio HAL and tinyplay present in stock | Unverified; no playback or audible observation |

HDMI capabilities list 720p and 1080p; this is not confirmation of visible
output. The framebuffer virtual dimensions do not establish its visible
dimensions, stride, channel order or safe mapping length; obtain these from
framebuffer ioctls before drawing. No framebuffer or mixer writes occurred.

The HDMI `aud_cap` read returned only the column heading and no codec entries.
`audio_on` does not exist at the inspected path. Sink audio support and actual
audio routing remain UNKNOWN. The stock audio policy lists HDMI stereo
PCM16 at 48000 Hz, but this is configuration evidence only. ALSA device nodes
are system:audio mode 0660; the current unprivileged custom ADB shell must not
be assumed to have playback permission. The current RAM rootfs does not
include the stock Android audio HAL or tinyplay.

At the initial baseline, the custom RAM rootfs had no DHCP client, interface setup command, display
renderer or PCM player. PID1 currently exposes normal Android return through
its narrow control service; it does not expose a general root shell. These
controls need deliberate implementation rather than attempting privileged
network or device writes from UID2000. Wi-Fi firmware-path access was denied;
the nvram parameter path was absent. Firmware locations remain UNKNOWN.

Bring-up sequence:

1. Ethernet: implement explicit RAM-only interface setup and DHCP with bounded
   timeouts, preserving USB ADB; validate lease/address/route and actual traffic.
   Do not reuse the observed stock IP as a static assignment.
2. HDMI: inspect framebuffer fixed/variable info, retain the existing timing,
   render a reversible test pattern, and require an owner-visible observation.
3. Audio: inspect actual ALSA capabilities and routing, provide explicit
   short-duration PCM playback, and require an owner-audible observation.
   Begin with conservative amplitude and no unbounded loop.
4. Give every new RAM candidate separate hashes and local regression evidence;
   retain the existing known-good candidates and verify normal Android return.

No RAM boot or image rebuild was performed during this initial baseline.
No persistent installation, display mode change, mixer change or reboot was
performed. Network activity was limited to three gateway pings.

## Hardware candidate implementation

A separate `Hardware` preset now packages `/sbin/mibox-hardware` alongside the
updated init and toolbox. Existing presets keep their previous image pins.
The helper is static ARM ELF32 hard-float, built with Ubuntu GCC 13.3 and a
locally extracted cross sysroot. Package and source hashes are retained in
`artifacts/network-hdmi-audio/hardware-candidate/helper-manifest.json`.

The PID1 control service accepts only `network`, `display` or `audio`, from
UID0/UID2000, with the current boot ID. It executes the fixed root-owned helper
without a shell and retains ownership of its child until exit. The helper
requires root, parent PID1, the custom OS marker, stock board/kernel identity
and RAM/virtual mounts. It has a 45-second alarm and PID1 imposes a 50-second
process deadline. Existing normal Android return remains available after tests.
These requests do not run automatically at boot.

- `network`: require eth0 initially down and unaddressed, raise it, obtain a
  DHCP offer/ACK through AF_PACKET, validate transaction/MAC/options/server and
  subnet/lease, probe for an address conflict, configure IPv4 and a default
  route, and require three matching gateway ICMP echo replies. Then remove
  the route/address and restore interface flags. This is a bounded smoke test,
  not a lease renewal service or DNS/Internet validation. It sends no RELEASE;
  the router's unused lease can remain reserved until expiration.
- `display`: derive visible region, stride, memory bounds and RGBA fields from
  framebuffer ioctls. Accept only a checked packed 32-bit truecolor layout,
  save the visible memory rows, show eight color bars for 15 seconds, and restore
  the saved bytes. No mode, scaling, blanking or display-axis configuration is
  changed. Successful writes alone do not prove visible HDMI output.
- `audio`: open ALSA PCM card0/device0, negotiate 48000 Hz stereo PCM16,
  submit 144000 frames of faded 440 Hz left/660 Hz right tones at 3% amplitude,
  then drop/free/close the stream. No mixer or HDMI mode is changed. Successful
  PCM writes alone do not prove HDMI audio routing or audible output.

The framebuffer API follows the [Linux framebuffer documentation](https://www.kernel.org/doc/html/latest/fb/api.html).
The DHCP exchange uses [RFC 2131](https://www.rfc-editor.org/rfc/rfc2131).
Kernel ioctl structures/constants come from the recorded ARM cross UAPI headers.

Candidate image SHA256:
`ac2939921a9fb44f5c918c3c8f7f1e5f6dff2dbd48d6142583b18f4c6976cd28`.
Size: 8388608 bytes; stock kernel, DTB, load addresses and cmdline retained.
Executable pins:

| Executable | SHA256 |
| --- | --- |
| /init | c9685fe4a4e6892a273917e0b82f77d0cd74320245d43ec413cea8b59b213c4b |
| /bin/mibox | e8fa69daba2bb78b42fdff17ca3819fe2bcf5afb007c129aad3384e0053adecf |
| /sbin/mibox-hardware | 1e47e6ea7ae9200e1613200f7c9ccb60c554979ee0d139635f8d3c66ce862f71 |

Local validation passed: formatting/build, 23 record-validator and nine
orchestration guard cases, five parser fixtures plus 100000 ASan/UBSan inputs,
13/13 actual-rootfs QEMU stages including wrong-kernel refusal, and QEMU normal
restart/platform-guard tests including malformed/stale hardware requests.
Four host namespace tests passed: DHCP/gateway/cleanup, DHCP NAK/cleanup,
address-conflict refusal/cleanup and changed-server refusal/cleanup. These
namespaces have no host network connection. None is physical network evidence.

Reproduce the host parser and isolated network tests in WSL:

```sh
python3 scripts/test-hardware-parser.py
# The script refuses to modify a namespace shared with PID1.
sudo unshare --net -- python3 scripts/test-hardware-network.py
```

Explicit physical test commands after booting the pinned Hardware candidate:

```powershell
powershell -NoProfile -File scripts/ram-boot.ps1 -Action Boot -Candidate Hardware
powershell -NoProfile -File scripts/Test-MiboxHardware.ps1 -Action Network
powershell -NoProfile -File scripts/Test-MiboxHardware.ps1 -Action Display
powershell -NoProfile -File scripts/Test-MiboxHardware.ps1 -Action Audio
```

Each test pulls and hashes all three executables, checks boot identity and
restart readiness, verifies actual helper/toolbox exit status, and saves
separate evidence. Display/audio reports retain `FunctionalPass=false` until
the corresponding owner observation exists. Audio observation is unavailable
with the currently connected monitor-only setup.

## First physical outcome and owner network clarification

`Hardware` booted successfully after all 8388608 RAM bytes were verified.
Custom boot ID: `158776f1-48d4-4da9-af0a-dcde271c2848`.
Evidence: `artifacts/ram-boot/20261114-195500-219/` and the separate Network,
Display and Audio records under `artifacts/network-hdmi-audio/`.

- Ethernet carrier came up and traffic counters advanced, but the DHCP client
  timed out waiting for an Offer. The interface was down again with no IPv4
  routes after cleanup. The owner subsequently confirmed that DHCP is disabled
  and the box uses a fixed address. Thus this timeout does not establish an
  Ethernet driver failure; DHCP was the wrong configuration method for this LAN.
- Framebuffer writes and restoration succeeded. The owner reported
  **only the official logo**, so visible custom HDMI output did not pass.
  Actual framebuffer layout: 1280x1080, virtual 1280x3240, 5120-byte stride,
  16 MiB memory, RGBA offsets 0/8/16/24 with eight bits each.
- ALSA accepted all 144000 stereo PCM frames. Audible output remains UNKNOWN
  with the monitor-only setup; no HDMI audio routing pass is claimed.
- Normal Android return passed independently, retaining the stock fingerprint
  and completed startup. Result:
  `artifacts/software-return/return-20261114-202241/result.json`.

The exact first helper source is preserved alongside its manifest in
`hardware-candidate/source/`; the original physical records remain unchanged.

## Display handoff and static-IP candidate

`Hardware2` added software UDP checksums, bounded Ethernet/DHCP diagnostics and
a framebuffer handoff using the same queried geometry, pan offset and unblank
ioctls. Its local QEMU/parser/network tests passed. The first upload session
was interrupted before a final result; the subsequent complete retransmission
was stopped after the owner clarified that DHCP was disabled. It has **no
verified physical boot**. Its separate manifests and stop record are retained
under `hardware2-candidate/`.

The owner explicitly confirmed this fixed configuration for `Hardware3`:

| Setting | Confirmed value |
| --- | --- |
| IPv4 address | 192.168.1.222 |
| Netmask | 255.255.255.0 (/24) |
| Gateway | 192.168.1.1 |

The profile is a root-owned, read-only `/etc/mibox-network-static` in the RAM
image. The helper rejects symlinks, non-regular files, non-root ownership,
group/other write permission, oversized/malformed content and invalid subnet
configuration. When the file exists, the network test uses this explicit
profile without sending DHCP. It still checks for address conflicts, tests
three gateway echoes, then removes the address/route and restores eth0 down.
It does not apply the configuration automatically at boot or retain a live
network after the test. Empty FIB contents are valid after removing all routes;
the host verifier requires the actual read exit status rather than a header.

The display test now reapplies the exact framebuffer geometry with
`FBIOPUT_VSCREENINFO`, pans to its queried offset, and unblanks via `FBIOBLANK`.
This explicitly hands scanout to the framebuffer instead of assuming a memory
write replaces the bootloader logo. Saved framebuffer bytes are restored after
15 seconds; the previous bootloader scanout state is not claimed restored.
No raw physical addresses, display timing changes or persistent settings are
used. Normal Android return is the final restoration check.

`Hardware3` image SHA256:
`5f6a5654e5603c7abaeb9dca21996bc5a6e3bc0a83b650c8e0e347de100fdd55`.
Helper SHA256:
`1d21c17cfec18992a104e163180fea5b632ec06290b452e19a9b200504c379d3`.
Init/toolbox pins remain those listed above. Separate evidence is under
`artifacts/network-hdmi-audio/hardware3-candidate/`.

Local checks passed: 13/13 actual-rootfs QEMU stages, parser ASan/UBSan tests
and seven isolated network cases, including static gateway/cleanup, static
address-conflict refusal and malformed-profile refusal. The host DHCP fixture
also verifies the generated request UDP checksum. These are host checks only.

Select the candidate explicitly when reproducing:

```powershell
powershell -NoProfile -File scripts/ram-boot.ps1 -Action Boot -Candidate Hardware3 -ControlTimeoutMilliseconds 10000
powershell -NoProfile -File scripts/Test-MiboxHardware.ps1 -Action Network -Candidate Hardware3
powershell -NoProfile -File scripts/Test-MiboxHardware.ps1 -Action Display -Candidate Hardware3
```

The existing loader is being reused after interruption, with a new complete
upload/readback rather than unverified partial RAM contents. This run does not
send another loader-mode request or reset. Its retained-process wrapper and
baseline provenance are preserved with the candidate evidence. Physical run:
`artifacts/ram-boot/20261114-204540-498-resume-hardware3/` failed with Win32 121
while writing RAM address 0x820bd100. No complete transfer or boot is verified
for that attempt. A bounded read-only identify/boot-buffer probe then passed
(`20261114-205417-603-loader-diagnostic`), so no reset or power cycle was needed.

The subsequent user-authorized full retry is
`artifacts/ram-boot/20261114-205603-859-resume-hardware3/`. It uses a bounded
10000 ms EP0 control timeout instead of 3000 ms. Both the loader script and
orchestrator expose `-ControlTimeoutMilliseconds` in the range 3000..15000;
their default remains 3000. Image bytes and complete-readback requirements are
unchanged. This attempt's final result must establish success separately.

## Hardware3 physical result

The full 8388608-byte transfer/readback passed with the pinned SHA256 and a
10000 ms control timeout, taking 1311.41 seconds. The boot ID was
`49c3b52c-4d60-4bbc-9eac-8a502088108c`. All three executable readbacks matched
the pins, and each hardware test verified the same boot identity and restart
readiness before and after its action.

| Function | Final evidence | Outcome |
| --- | --- | --- |
| Wired IPv4 | Owner-confirmed 192.168.1.222/24, gateway 192.168.1.1; three echo replies; address/route removal, eth0 down and independent FIB read | PASS for this bounded LAN test |
| HDMI | Same-geometry fbdev handoff/pan/unblank, 15-second color bars, framebuffer bytes restored; owner explicitly replied "有看到色條" | PASS for visible test output |
| PCM | ALSA card0/device0 accepted 144000 frames at 48000 Hz, stereo PCM16 | PASS for frame submission |
| Audible output | Monitor-only setup, no audible observation | UNKNOWN |
| Framebuffer capture | Actual `/dev/fb0` pull rejected with Permission denied for UID2000 | No screenshot captured |
| Android return | Normal restart, original fingerprint, boot_completed=1 and new boot ID | PASS |

Independent Android boot ID after return:
`ef41a5b6-63c1-4b64-b5c5-77997198614c`.

The automatic resume wrapper reported failure because the observer exited 0
but its redirected output streams did not complete. The saved observer result
independently confirmed the custom OS, and the subsequent executable readbacks,
fixed-IP/HDMI/PCM actions and software-return proof established the physical
results above. The original wrapper failure has **not** been rewritten as an
automatic end-to-end pass. The exact reason for the open output stream is
UNKNOWN; no boot or transfer retry was needed after this observer error.

Evidence:

- [Validated physical summary](../artifacts/network-hdmi-audio/hardware3-candidate/physical-summary.json)
- [Fixed-IP test](../artifacts/network-hdmi-audio/20261114-211941-285-network/result.json)
- [Framebuffer handoff](../artifacts/network-hdmi-audio/20261114-212016-515-display/result.json)
- [Owner-visible color bars](../artifacts/network-hdmi-audio/20261114-212016-515-display/owner-observation.json)
- [PCM submission](../artifacts/network-hdmi-audio/20261114-212058-803-audio/result.json)
- [Framebuffer capture permission result](../artifacts/network-hdmi-audio/20261114-211958-419-framebuffer-capture/framebuffer-fb0-readback.json)
- [Independent Android return](../artifacts/software-return/return-20261114-212103/result.json)

That Hardware3 image has no root screenshot action. Android `screencap`
and SurfaceFlinger are not included; UID2000 cannot directly read the current
framebuffer device. A framebuffer snapshot, if implemented in a later image,
would still need to be distinguished from the actual HDMI scanout: the first
candidate demonstrated framebuffer writes while the owner still saw the logo.
No screenshot or audible-output success is inferred from the visible color bars.

Subsequent separate Capture and DisplayCapture candidates add a fixed root
framebuffer snapshot action. DisplayCapture physically captured its live eight
color bars and passed exact pixel validation; see
[framebuffer capture results](mibox-framebuffer-capture.md#live-color-bar-capture-2026-11-15).
The historical Hardware3 permission failure above remains unchanged.

## Observer process bounds follow-up (2026-11-15)

The observer now uses the shared retained-process runner for each ADB query,
replacing unbounded exit/stream waits with bounded execution, cleanup and EOF
checks. Nonzero, timed-out or incomplete identity queries cannot establish
the custom OS marker. The shared runner records stdout and stderr completion
separately and waits for both independently, preserving its strict EOF gate.

Host-only checks passed: process fixtures 5/5, observer fixtures 4/4 and
orchestration guards 9/9. No device access or RAM boot was performed in this
follow-up. The historical outer-wrapper failure remains unchanged and its
root cause remains UNKNOWN; these checks do not establish a physical fix.

The extended process suite passed 6/6, including a root exiting 0 while its
live descendant holds both output pipes. The runner rejected incomplete EOF
within its bounds and did not attempt cleanup using the exited root PID.
The fixture descendant's identity was checked by PID and creation time and
it exited naturally. Evidence:
`artifacts/ram-boot/process-tests-20261115-055956-389/results.json`.
This demonstrates a possible mechanism; it does not identify the historical
hardware failure's cause.
