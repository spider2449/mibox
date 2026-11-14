# Isolated stock ADB console compatibility test

1. [x] Package exact stock recovery adbd/sh into an optional QEMU-only rootfs.
2. [x] Build a probe gated on QEMU device tree and an explicit test boot flag.
3. [x] In the isolated guest only, bring up loopback/devpts and start stock adbd.
4. [x] Exercise ADB framing and run the custom toolbox through the shell service.
5. [x] Stop test daemon, preserve transcripts and recheck PID1/reaper operation.
6. [x] Create a dedicated host-only test key and package only its public key.
7. [x] Enable authentication in QEMU properties; reject a bad signature before accepting a valid one.
8. [x] Recheck the normal mode and missing-flag guard after authenticated console integration.

No real device operations, host NIC, host port forwarding or persistent disk.
This tests userspace/protocol dependencies, not the physical FunctionFS USB
transport. Never run the probe on the MiBOX; it must refuse non-QEMU hardware.

Normal compatibility test and missing-flag refusal test both passed 11/11.
Initial missing-property-area SIGSEGV was diagnosed using bounded ptrace and
fixed by initializing an empty read-only ABI-compatible QEMU property area.
See docs/mibox-adb-console-qemu.md. Authentication and physical USB remain open.

Follow-up implements signed challenge exchange over QEMU serial: OpenSSL signs
on the host, while the guest sends ADB AUTH packets. No owner private key is
read; no private key enters an initramfs. Only a new disposable test key is used.

All three current modes passed 11/11, including invalid-signature rejection,
valid signature acceptance and a shell response as UID2000. Physical USB and
independent boot remain untested; no production key provisioning was attempted.
