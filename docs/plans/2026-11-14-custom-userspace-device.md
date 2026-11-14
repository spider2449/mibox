# Custom userspace on the physical stock kernel

1. [x] Build a static ARMv7 toolbox without Android executable/library dependencies.
2. [x] Build a fixed root launcher that prepares a dedicated scratch rootfs.
3. [x] Run chroot child after dropping groups/GID/UID, with no mounts or device nodes.
4. [x] Verify custom OS identity, actual kernel, rootfs visibility, file I/O and child exec.
5. [x] Save evidence and continue offline update/boot selection analysis.

Physical device runs passed twice. PID1 toolbox integration then passed 10/10
QEMU stages in normal and absent-gadget fallback cases. Embedded stock config
recovered; kexec/namespaces explicitly disabled. Actual OTA verification call
and slot selection property references traced. See docs/mibox-custom-userspace.md
and docs/mibox-software-boot-analysis.md.

No PID1 claim: the box lacks a demonstrated PID namespace. This is a custom
userspace process under stock Android's kernel. Do not run init's PID1 path,
mount eMMC, change SELinux, switch USB or call update/boot services in this test.
