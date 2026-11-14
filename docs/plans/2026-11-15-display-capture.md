# Capture the live display test pattern

1. [x] Capture framebuffer inside the display action, before restoring its bytes.
2. [x] Add host display/capture selection and verify exact eight-color pixels.
3. [x] Build and pin a separate DisplayCapture RAM image; preserve earlier pins.
4. [x] Boot with full RAM readback, capture and verify pattern, return to Android.

RAM-only, no flash or persistent install. Audio listening remains deferred.
Captured pixels do not independently prove HDMI scanout.

Local gates passed: actual-rootfs QEMU 13/13; capture host fixtures 7/7,
including valid color bars and a one-byte corruption; ASan/UBSan capture layout
fixtures and 100000 geometry inputs; exact color-bar conversion, gray/corrupt
image rejection. ARM helper is static, SHA256
`62d3f1c0748f625ab363a254080fe45ddbf445741b172fae53198cd0ace8fda3`.
Separate 8388608-byte image SHA256:
`19c7064bc3e389a8f63ba70847ae7628e8366d38644b187f9cec89e33dccf2fb`.
Candidate manifests and local evidence: `artifacts/display-capture/`.

Physical workflow: `ram-boot.ps1 -Action Boot -Candidate DisplayCapture
-ControlTimeoutMilliseconds 10000`, then `Capture-MiboxFramebuffer.ps1
-ManifestPath artifacts/display-capture/candidate/rootfs-manifest.json
-DisplayPattern`, then `Test-MiboxSoftwareReturn.ps1 -Candidate DisplayCapture
-AndroidBaseline` using that same boot run's baseline. The display helper restores
the previous framebuffer even when capture fails. Each successful display test
now also requires successful capture; older pinned candidates remain unchanged.

Physical PASS: full 8388608-byte readback, custom identity and health passed in
`artifacts/ram-boot/20261115-072208-114/`. Actual 1280x1080 capture in
`artifacts/framebuffer-capture/20261115-074424-576/` matched every expected
eight-color pixel, was visually inspected, and reported framebuffer_restore=ok.
Normal return passed in `artifacts/software-return/return-20261115-074507/`:
original fingerprint, boot_completed=1, Android boot ID
`209b6e50-b891-4a83-b5fd-faeb2e77e240`, different from baseline and custom boot.
Linked summary: `artifacts/display-capture/physical-summary.json`.
No new owner HDMI observation was obtained; scanout is not claimed for this run.
