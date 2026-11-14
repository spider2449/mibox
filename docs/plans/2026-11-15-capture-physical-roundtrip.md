# Capture physical RAM round trip

Owner instructed continuation after the locally validated Capture candidate.
Audio listening remains deferred. Use the established RAM-only upload/boot
workflow; no flash, erase, saved bootloader environment or persistent install.

1. [x] Verify retained-process fixtures, pinned image and completed stock baseline.
2. [x] Upload all 8388608 bytes and verify complete RAM readback before boot.
3. [x] Verify custom boot ID, executable hashes, health and restart readiness.
4. [x] Request capture; pull PPM, validate/convert PNG and inspect actual pixels.
5. [x] Verify normal return to original completed Android with a changed boot ID.

Capture candidate SHA256:
`03c2fec77ece8dada455a4be2b818ee377c4957d56ce97a3675406243832f53b`.
Use a 10000 ms control timeout. Preserve all original failures; inspect device
state before recovery decisions. A framebuffer image is not proof of HDMI scanout.

Physical run started 06:13 Asia/Taipei. Evidence:
`artifacts/ram-boot/20261115-061309-246/`.
Retained-process fixtures passed 6/6. Baseline boot ID:
`6afdf09a-f36b-4499-9852-e069524d35d1`, original stock fingerprint,
`sys.boot_completed=1`.

Completed: full transfer/readback and custom health passed in the boot-run
`result.json`. Capture evidence is
`artifacts/framebuffer-capture/20261115-063756-206/`: 1280x1080, every RGB
pixel (128,128,128), PPM/PNG hashes independently rechecked. This is a gray
framebuffer, not evidence of color bars or actual HDMI scanout.

The original return observer record in
`artifacts/software-return/return-20261115-063833/` was interrupted after its
single restart request; its result lacks a final verdict and events contain
trailing NUL bytes. Preserve these files unchanged. A later read-only check
independently verified the original fingerprint, boot_completed=1 and Android
boot ID `5dc5dda3-0805-4138-9218-75822a581c85`, different from both baseline
and custom boot IDs. Evidence:
`artifacts/software-return/verification-20261115-064518/`.
No restart request was repeated. Exact Android completion time is UNKNOWN.
