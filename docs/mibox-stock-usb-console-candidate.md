# Stock USB console components: offline candidate

The recovery cpio contains ARM ELF32 executables sbin/adbd (166052 bytes) and
sbin/sh (214916 bytes). Both have no PT_INTERP or PT_DYNAMIC program header,
so these copies do not require Android shared libraries or a dynamic loader.
Hashes and program-header facts are recorded in
artifacts/platform/2026-11-14/recovery-config/manifest.json.

The bounded cpio parser now optionally extracts only those two additional
regular files to a private binary directory. It still validates the archive
trailer, bounds, file types and duplicate names. The extractor executes no code.
Subsequent isolated QEMU execution of these exact binaries passed baseline,
authenticated ADB shell and guard tests, each 11/11; see mibox-adb-console-qemu.md.

adbd strings identify the vendor kernel's existing /dev/usb-ffs/adb/ep0-ep2
path, /system/bin/sh and /adb_keys or /data/misc/adb/adb_keys. This is a more
direct candidate for a future USB control channel than requiring UART hardware
changes. Userspace/protocol operation is now tested in QEMU. Physical USB and
standalone hardware boot remain untested.

Required follow-up before enabling it in a hardware boot:

1. Match the already captured recovery FunctionFS mount/gadget configuration.
2. Provide the shell path and owner-authorized public ADB keys in the RAM rootfs.
3. Provision the owner's authorized public keys for a hardware-targeted image.
   QEMU now confirms property-area compatibility, UID2000 shell execution,
   rejection of an invalid signature and acceptance of a dedicated test key.
4. Verify a software boot and return path; do not test gadget replacement inside
   the current Android session. Live USB ACM switching remains suspended.

Separately, the CRC-verified saved environment routes reboot_mode=usb_burning
to the existing usb_burning variable, whose value is update 1000. This is a
static software-entry lead, not a verified burning protocol, RAM-loader or
restore path. No reboot into that mode or boot environment write was performed.
Full reference graph: artifacts/platform/2026-11-14/saved-bootgraph.json.
