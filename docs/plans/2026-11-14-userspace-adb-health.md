# Standalone health through stock ADB

Host/QEMU only. Keep the physical-tested RAM candidate pinned and unchanged.

1. [x] Extend the guarded QEMU ADB probe with a separate toolbox health stream.
2. [x] Require explicit shell exit status and match the guest boot identity.
3. [x] Run stock ADB baseline, authenticated, and missing-flag refusal checks.
4. [x] Record executable/initramfs provenance and old-kernel compatibility limits.

All three QEMU modes passed 12/12 stages. Baseline and authenticated modes
verified the standalone health output; the guard refused to start the probe.
Fifteen stock configuration prerequisites are explicitly y in the pinned
extracted config. This does not establish runtime compatibility with 3.10.33.
Evidence: artifacts/userspace-adb-health/2026-11-14/.
