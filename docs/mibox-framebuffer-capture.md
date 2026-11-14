# Framebuffer capture from custom RAM userspace

Status: **physical RAM capture and independent completed Android return verified**.
The owner deferred audio listening on 2026-11-15; audibility remains UNKNOWN
and is not a blocker for this work.

The new fixed `capture` action uses the existing UID0/UID2000 PID1 control
socket and current boot ID. The root helper retains the stock-platform and
RAM-only-mount guards. It opens fb0 read-only, queries geometry, bounds the
visible region and validates nonoverlapping RGB/alpha fields. It supports
packed 32-bit truecolor with eight-bit RGB channels, up to 4096x2160.
It exports visible RGB pixels without row padding or alpha as binary PPM.
No display mode, pan, unblank, mixer or framebuffer writes are issued.

The helper creates a private temporary file exclusively in root-owned `/dev`,
sets the completed file readable by ADB, then atomically publishes
`/dev/mibox-framebuffer.ppm`. Failed captures remove their own temporary file;
any previous completed capture remains unchanged. The host requires a fresh
successful helper result before pulling. Captures occupy RAM and disappear
at reboot. This is a sequential framebuffer read, not an atomic display snapshot;
content may change during capture, and it does not prove actual HDMI scanout.

`Capture-MiboxFramebuffer.ps1` verifies custom OS, boot ID, all three executable
hashes against an explicitly supplied rootfs manifest, and restart readiness.
It requests capture, pulls the PPM, validates its bounded format and converts
to PNG using standard Python libraries. It uses Windows Python when available,
otherwise WSL Python. Afterward it rechecks boot identity and restart readiness,
and records image hashes. Failures remain failures, even if an image file exists.

The separate `Capture` candidate preserves all earlier image pins and defaults.
Its image is 8388608 bytes with SHA256
`03c2fec77ece8dada455a4be2b818ee377c4957d56ce97a3675406243832f53b`.
It retains the stock kernel/DTB, load addresses and cmdline, plus the previously
owner-approved RAM-only static test profile. Neither network setup nor capture
runs automatically. Local build manifests and source hashes are under
`artifacts/framebuffer-capture/candidate/`.

Local checks passed:

- ASan/UBSan capture fixtures: padded rows, x/y offsets, RGB/BGR, alpha ignored,
  invalid geometry/channel layouts, truncated reads and failed I/O; 100000 geometry inputs.
- PNG conversion: RGB bytes, dimensions, chunk CRCs and five invalid inputs.
- Existing DHCP parser fixtures and 100000 ASan/UBSan inputs.
- QEMU on the actual new rootfs: 13/13 stages, including wrong-kernel helper refusal.
- Host capture orchestration: 5/5 using fake ADB and the actual PNG converter.
- Existing RAM boot orchestration guards: 9/9; Capture local check and unchanged
  Hardware3 pin verification passed without USB access.
- QEMU platform guard and normal restart passed, including rejection of capture
  requests from an unauthorized UID, a stale boot ID and an unsupported platform.

The subsequent physical run completed the full 8388608-byte upload and matching
RAM readback before boot. Custom boot identity, executable hashes, health and
restart readiness passed. Evidence:
[boot result](../artifacts/ram-boot/20261115-061309-246/result.json) and
[capture result](../artifacts/framebuffer-capture/20261115-063756-206/result.json).

The [captured PNG](../artifacts/framebuffer-capture/20261115-063756-206/framebuffer.png)
is 1280x1080 and uniformly gray: every RGB pixel is (128,128,128).
Visual inspection and independent PPM byte checks agree; both saved image hashes
match the capture result. This verifies framebuffer readback, not color bars or
physical HDMI scanout.

The original return observer was interrupted after sending its single normal
restart request. Its incomplete result and trailing NUL bytes in events remain
unchanged. A [later independent read-only verification](../artifacts/software-return/verification-20261115-064518/result.json)
confirmed the original stock fingerprint, boot_completed=1, and a new Android
boot ID different from both baseline and custom runtime. No repeat restart was
sent. Exact completion time and the original observer interruption cause remain
UNKNOWN. This run used temporary RAM boot; no flash command was sent.

To reproduce from completed Android:

```powershell
powershell -NoProfile -File scripts/ram-boot.ps1 -Action Boot -Candidate Capture -ControlTimeoutMilliseconds 10000
powershell -NoProfile -File scripts/Capture-MiboxFramebuffer.ps1 -ManifestPath artifacts/framebuffer-capture/candidate/rootfs-manifest.json
powershell -NoProfile -File scripts/Test-MiboxSoftwareReturn.ps1 -Candidate Capture -AndroidBaseline artifacts/ram-boot/<boot-run>/android-baseline.json
```

The final command needs the baseline produced by that same boot run. Physical
validation must independently establish completed Android return; a successful
capture does not establish that return or complete hardware support.

## Live color-bar capture (2026-11-15)

The separate `DisplayCapture` candidate captures the framebuffer inside the
display helper after its same-geometry handoff/pan/unblank and before restoring
the original bytes. Its `display` action now requires capture success as well
as restoration. The standalone `capture` action remains read-only.

Physical [capture result](../artifacts/framebuffer-capture/20261115-074424-576/result.json)
passed: 1280x1080, with every pixel matching the eight expected vertical bars
(white, yellow, cyan, green, magenta, red, blue, black).
The [actual PNG](../artifacts/framebuffer-capture/20261115-074424-576/framebuffer.png)
was also visually inspected. The helper reported successful framebuffer
restoration. This establishes drawing plus framebuffer readback; this run has
no new owner observation of the HDMI sink, so actual scanout remains unverified
for this candidate.

The new 8388608-byte image SHA256 is
`19c7064bc3e389a8f63ba70847ae7628e8366d38644b187f9cec89e33dccf2fb`.
The [boot record](../artifacts/ram-boot/20261115-072208-114/result.json)
confirms full RAM readback, custom boot identity, executable hashes and health.
Earlier candidate pins are unchanged. Local QEMU passed 13/13 stages; host
capture fixtures passed 7/7 including exact pattern and corrupt-pixel cases;
capture sanitizer/geometry checks also passed.

Use `-Candidate DisplayCapture` for RAM boot/return, and run
`Capture-MiboxFramebuffer.ps1 -ManifestPath artifacts/display-capture/candidate/rootfs-manifest.json -DisplayPattern`
to require fresh capture, successful restoration and exact color-bar pixels.
Omit `-DisplayPattern` for a read-only snapshot.

The [same-run Android return](../artifacts/software-return/return-20261115-074507/result.json)
also passed automatically: original stock fingerprint, boot_completed=1 and
Android boot ID `209b6e50-b891-4a83-b5fd-faeb2e77e240`, distinct from baseline
and custom boot. No flash command was sent. The
[linked physical summary](../artifacts/display-capture/physical-summary.json)
connects boot, screenshot and return evidence.
