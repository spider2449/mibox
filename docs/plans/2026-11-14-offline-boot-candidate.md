# Offline stock-kernel/custom-rootfs boot candidate

1. [x] Build authenticated USB RAM rootfs with explicit read-only opt-in marker.
2. [x] Verify original boot1 full hash, section bounds, Android ID and zero tail.
3. [x] Preserve original kernel/DTB and header load addresses; replace only ramdisk and its size/ID.
4. [x] Independently inspect generated image and recheck rootfs no-gadget fallback.
5. [x] Record NOT READY status and exact artifacts; do not upload, flash or reboot it.

This is a local, reversible build, not evidence of loader acceptance. Boot image
signature policy, hardware USB console and software recovery remain unverified.
The rootfs marker avoids assuming the bootloader honors a new header cmdline.

Image SHA256 f05adbc3d79c8f41be7fef1145f6111f436d35921b7051722ae5195ae7624bba.
Independent extraction validated Android ID, newc trailer, kernel and DTB hashes.
