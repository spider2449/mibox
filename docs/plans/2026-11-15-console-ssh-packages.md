# Console, SSH and package installation

Requested: console-only Linux with SSH login and software installation.

1. Build a separate ARMv7 Alpine userspace with BusyBox, apk and an SSH server,
   retaining the custom PID1, authenticated USB ADB and normal Android return.
2. Use owner public-key authentication, wired Ethernet and the previously
   confirmed static LAN profile. Keep passwords disabled.
3. Validate shell, PTY SSH, DNS, HTTPS package retrieval, installation and an
   installed program in QEMU before any device boot. QEMU is not hardware proof.
4. Check RAM image size and preserve all previous candidate pins. If the full
   userspace cannot fit, stage a separately hashed RAM payload through USB ADB.
5. Validate on the actual stock 3.10.33 kernel, including independent Android
   return. Record exact blockers rather than claiming readiness from host tests.

The owner subsequently requested persistence. After RAM console validation:

6. Inspect the verified data partition (179:11, 5168640 sectors) and free space.
   Use only a dedicated `/mibox-console` directory in its existing ext4 filesystem;
   do not format, resize, or modify Android files outside that directory.
7. Keep PID1 and USB rescue in RAM. Run login shells in a persistent Alpine
   chroot with explicit dev/proc/sys bind mounts. Restore it after each RAM boot
   through the host launcher; automatic power-on boot is a separate feature.
8. Test persistence with a virtual disk first, then actual package/config hashes
   across an Android return and a fresh full-readback RAM boot. Cleanly unmount
   data before invoking the existing RAM-only restart gate.

## Completed physical validation

- Console image SHA256: `4629deefd4e5e0f1902a54158ef01c7ad67156ef87946fb6d87c7070ba5da7c0`.
- Initial full-readback RAM boot: `artifacts/ram-boot/20261115-080653-993`.
- Physical SSH/PTY/DNS/HTTPS/package checks: `artifacts/console-ssh/device-20261115-083420`.
- Persistent baseline: `artifacts/console-ssh/persistence-20261115-083834`.
- Clean data unmount and Android return: `artifacts/software-return/return-20261115-083851`.
- Second full-readback RAM boot: `artifacts/ram-boot/20261115-084050-770`.
- Persistent restoration: `artifacts/console-ssh/launcher-20261115-084050`.
- Different physical boot ID, unchanged executable/database/config hashes and
  working persistent PTY: `artifacts/console-ssh/persistence-20261115-090313`.

Left running Linux with persistent console enabled. Default power-on boot
remains Android; use the launcher again to enter Linux after a power cycle.
The original restart guard remains strict and requires clean storage unmount.
