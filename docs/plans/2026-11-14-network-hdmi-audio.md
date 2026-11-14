# Network, HDMI and audio validation

2026-11-15 owner update: audio listening is deferred ("聲音聽測先忽略").
Audibility remains UNKNOWN and is not a blocker for current development.

1. [x] Inspect existing runtime support and collect a bounded stock baseline.
2. [x] Confirm connected network/display/audio equipment with the owner.
3. [x] Use the baseline to identify custom RAM userspace driver, firmware and control requirements.
4. [ ] Validate each function separately with actual traffic, visible output and audible output;
   retain exact candidate hashes, device evidence and owner observations.

Initial baseline did not change network/display/mixer settings or reboot.
Stock Android observations do not establish custom RAM userspace functionality.
Missing or inaccessible values remain UNKNOWN. A linked HDMI sink or registered
sound card alone is not a functional pass.

Owner confirmed wired Ethernet and HDMI; Wi-Fi is not configured. Stock Ethernet
gateway ping passed 3/3. HDMI HPD=1 and mode=1080p; visible output and audible
playback have not been verified. See `../mibox-network-hdmi-audio.md` for the
baseline, evidence paths and implementation gaps.

Owner subsequently instructed continuation and questions only when needed.
Authorized continuation: build a separately hashed RAM candidate, use the
established verified RAM upload/boot path, perform bounded Ethernet, reversible
framebuffer and short PCM tests, then verify normal return to Android. No flash,
erase, saved bootloader environment or persistent installation. Wi-Fi is deferred.

5. [x] Cross-build bounded hardware helper and fixed-action PID1 control integration.
6. [x] Run parser, platform guard, QEMU PID1/restart and host orchestration regressions.
7. [x] Pin a separate Hardware candidate; boot with complete RAM readback verification.
8. [x] Verify network traffic, framebuffer handoff and PCM frame submission individually.
9. [x] Obtain owner visual observation and independently verify Android return.
10. [ ] Verify audible output with an audio-capable sink and an actual listening observation.

Local validation: actual rootfs QEMU 13/13; normal restart and platform guard;
23 record validators, 9 orchestration guards, 5 parser fixtures and 100000
ASan/UBSan inputs, plus 4 isolated DHCP/ICMP/error-cleanup integration cases.
Physical transfer started at 19:55, evidence `artifacts/ram-boot/20261114-195500-219/`.
Owner confirmed monitor-only setup: audible output remains unavailable for
physical confirmation, even if PCM frame submission succeeds.

First physical run: Hardware boot passed; DHCP offer timed out; owner saw only
the official logo despite successful framebuffer writes; ALSA accepted 144000
frames. Android return passed (`return-20261114-202241`). These are separate
outcomes, not an overall functional pass.

Owner then confirmed DHCP disabled and explicitly approved the fixed profile
192.168.1.222 / 255.255.255.0 / gateway 192.168.1.1. Hardware3 integrates that
read-only RAM profile and fbdev geometry/pan/unblank handoff. Local QEMU 13/13,
parser sanitizers and seven isolated network cases passed. Hardware2 transfer
was interrupted and later stopped for this scope correction; no physical pass
is assigned to it. Hardware3 complete transfer/readback started at 20:45:40,
reusing the existing loader without another mode request/reset. Evidence:
`artifacts/ram-boot/20261114-204540-498-resume-hardware3/`.

That Hardware3 transfer failed at RAM write 0x820bd100 with Win32 121. A fresh
bounded read-only loader identification and boot-buffer read passed. Owner
instructed continuation; a complete retry started at 20:56 with a 10000 ms
control timeout, unchanged image pin and no reset/mode request. Evidence:
`artifacts/ram-boot/20261114-205603-859-resume-hardware3/`.

Final Hardware3 result: full transfer/readback passed (1311.41 seconds). The
observer exited 0 and saved a valid custom-OS record, but the wrapper failed
its output-stream-completion gate. That failure remains recorded. Independent
subsequent checks validated all three executable hashes and the same custom
boot ID `49c3b52c-4d60-4bbc-9eac-8a502088108c`.

Static IPv4 gateway echoes passed 3/3 and cleanup/FIB checks passed. Fbdev
handoff succeeded and owner replied "有看到色條". ALSA accepted all 144000 PCM
frames; audible output remains UNKNOWN. Framebuffer capture was attempted at
the actual `/dev/fb0` and denied to UID2000; no screenshot is claimed.
Normal Android return passed with the stock fingerprint, completed boot and
new boot ID `ef41a5b6-63c1-4b64-b5c5-77997198614c`.

Validated evidence summary:
`artifacts/network-hdmi-audio/hardware3-candidate/physical-summary.json`.
The box is back on stock Android. No persistent installation or partition
write was performed by this work. Audible-output verification is the remaining
hardware gate; the automated wrapper's output-stream issue is separately open.
