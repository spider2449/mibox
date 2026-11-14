# RAM framebuffer capture

Audio listening is deferred by the owner; audibility remains UNKNOWN.

1. [x] Add a fixed capture action through the existing PID1 control channel.
2. [x] Read checked fbdev geometry and RGB channels without display writes.
3. [x] Publish a bounded PPM in root-owned devtmpfs for USB ADB readback.
4. [x] Test padded rows, offsets, channel orders, invalid layouts and read failures.
5. [x] Cross-build ARM helper and Rust userspace; retain separate evidence.

Host-only development. Preserve existing candidate pins and physical records.
No physical screenshot is claimed without a new separately pinned RAM boot.
Framebuffer content alone does not prove actual HDMI scanout.

Local results: capture ASan/UBSan fixtures plus 100000 geometry inputs and PNG
conversion checks passed; existing DHCP parser fixtures and 100000 sanitizer
inputs passed. Actual-rootfs QEMU 13/13; capture host orchestration 5/5;
RAM boot orchestration guards 9/9. The initial QEMU invocation used the wrong
archive filename and failed before boot; its evidence remains in qemu-rootfs,
and the corrected invocation is retained separately in qemu-rootfs-verified.
QEMU restart/platform-guard tests also passed with capture-specific unauthorized
UID, stale-boot and unsupported-platform rejection checks.

Separate Capture image: 8388608 bytes,
SHA256 `03c2fec77ece8dada455a4be2b818ee377c4957d56ce97a3675406243832f53b`.
Local candidate check passed; Hardware3's original image pin also passed.
Implementation and reproduction: `../mibox-framebuffer-capture.md`.
