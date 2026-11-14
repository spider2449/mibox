# Live toolbox on the physical custom boot

The standalone Rust toolbox now implements info, uname, id, uptime, mounts,
ps, net, ls, cat and ram-selftest. The original UID65534 chroot selftest is
preserved. No external Android programs or shared libraries are needed.

The new ARM binary was built with `cargo build --release --bin mibox-userland`,
then deployed into the already-running custom system at:

`/tmp/mibox-toolbox-3c2999254ff6`

Size: 478132 bytes. SHA256:
`3c2999254ff676a5012892bdb89e2caddc2197d5e5471c901a460ac9136834f0`.
Pulling the remote executable back produced the same hash.

All eight exercised commands returned the expected actual-device output:
info, uname, id, uptime, mounts, ps, net and ram-selftest. Evidence is retained
under artifacts/live-toolbox/2026-11-14/.

- Architecture armv7l, Linux 3.10.33.
- ADB user UID/EUID/GID/EGID 2000.
- PID1 is root init; adbd is its UID2000 child.
- Only RAM and virtual filesystems are mounted.
- eth0 is down, no routes observed; networking was not configured. Carrier
  reads on the down interfaces failed and are shown as UNKNOWN.
- RAM self-test wrote/read 65536 deterministic bytes, verified child exit 17,
  then removed its own exact scratch file and directory.
- Boot ID remained dd2afb3c-091b-4e84-bfde-d468ef3045b1.

The RAM self-test requires a custom OS marker, an unprivileged UID, a RAM root,
no separate mount under /tmp and a non-symlink /tmp before writing. It uses
exclusive file creation in a newly created directory. It does not open devices,
mount storage, configure network/USB or reboot.

Example:

```powershell
& .\phone-tools\platform-tools\adb.exe -s 248243005297 shell /tmp/mibox-toolbox-3c2999254ff6 ps
& .\phone-tools\platform-tools\adb.exe -s 248243005297 shell /tmp/mibox-toolbox-3c2999254ff6 net
& .\phone-tools\platform-tools\adb.exe -s 248243005297 shell /tmp/mibox-toolbox-3c2999254ff6 ram-selftest
```

`scripts/Push-MiboxRamToolbox.ps1` uses the local authenticated ADB server and
classic sync SEND with explicit regular-file mode 0755. This avoids requiring
an external chmod command in the minimal rootfs. It verifies the custom OS
marker before sending and limits its destination to a content-addressed /tmp
toolbox file. Protocol reference: AOSP android-4.4.2_r1 adb/file_sync_service.c,
do_send; cached in phone-tools/source-reference/aosp-4.4.2-file_sync_service.c.

The running `/bin/mibox`, PID1 and previously verified 8 MiB boot candidate
remain the original baseline. The new executable exists only in RAM; a future
rootfs rebuild must get a new manifest/hash and validation rather than silently
reusing the earlier boot proof. No persistent installation is claimed.
