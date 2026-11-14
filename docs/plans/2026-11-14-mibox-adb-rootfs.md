# Authenticated USB ADB RAM rootfs candidate

1. [x] Share the QEMU-validated read-only property-area builder.
2. [x] Add opt-in PID1 USB ADB setup guarded by stock compatible string and gadget preflight.
3. [x] Build a deterministic RAM rootfs with stock static adbd/sh and owner public key only.
4. [x] Exercise safe no-gadget fallback in QEMU; recheck authenticated console.
5. [x] Record candidate hashes and readiness without flashing or live USB switching.

No boot image header, kernel, DTB modification, partition write or reboot.
Hardware USB operation and software recovery remain NOT VERIFIED; this artifact
is not ready to flash. The QEMU-only probe/private test key must not be included.

10/10 candidate-rootfs marker/fallback stages and 11/11 full-property-set
authenticated ADB stages passed. The SoC compatible string is not a unique
motherboard identity. See docs/mibox-boot-candidate.md for precise limits.
