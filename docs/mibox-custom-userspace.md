# Custom userspace tested on the physical MiBOX1S

The custom ARMv7 Rust toolbox ran on the actual stock Linux 3.10.33 kernel in
its own chroot, with UID/EUID 65534. This is a userspace milestone, not an
independent boot or PID1 replacement. Android continued running outside it.

The rootfs contains only bin, etc and tmp. The executable is statically linked;
readelf shows no INTERP program header. It requires no Android executable or
shared library. A fixed temporary-root worker creates a fresh root-owned scratch
directory, enters it in a child, clears supplementary groups, then drops GID/UID
before executing custom code. No mounts, device nodes, USB changes, SELinux
changes, boot environment changes or partition writes are performed.

Actual device tests passed:

- info: custom /etc/os-release, actual kernel version and UID/EUID 65534.
- ls /: only bin, etc and tmp are visible.
- cat /etc/os-release: custom system identity.
- selftest: scratch-file write/read/delete, root-owned identity file cannot be
  opened for writing, Android /system and /data are absent, custom child exits
  with the expected code 17.

Evidence: artifacts/userspace/2026-11-14/device-transcript-final.txt and
provenance-final.json. The device executable SHA256 matched the host build:
27416a3aa406b7f760ebccd2070d56298f30efef75aa658e1beee583571f51d0.
Current scratch rootfs:
/data/local/tmp/mibox-userland-5607-1794611699537/rootfs.
No server, startup service or background userspace process remains after testing.
The scratch directories are retained for inspection.

## Build and run

The launcher embeds the exact previously built toolbox, so build in this order:

```powershell
cargo build --release --bin mibox-userland
cargo build --release --features device-userspace-test --bin mibox-userspace-test
$adb = '.\phone-tools\platform-tools\adb.exe'
& $adb -s 248243005297 push target/armv7-unknown-linux-musleabihf/release/mibox-userspace-test /data/local/tmp/mibox-userspace-test
& $adb -s 248243005297 shell 'chmod 755 /data/local/tmp/mibox-userspace-test; /data/local/tmp/mibox-userspace-test'
```

Each run uses a new directory and refuses to reuse an existing rootfs path.
The optional feature keeps the embedding launcher out of ordinary clean builds.
The test uses the already established temporary pppoe_wrapper root mechanism;
it does not install su or change the permanent ADB hook.

## PID1 integration

The custom init console now supports os and files, invoking the same toolbox
for system identity and root-directory listing. A mutex prevents PID1's generic
reaper from collecting the explicitly waited toolbox child prematurely.
The original orphan-child reaper test still passes.

The deterministic QEMU-only initramfs now contains /bin/mibox and /etc/os-release
in addition to init and virtual-filesystem directories. Both normal console and
requested-USB-with-no-gadget fallback runs passed 10/10 stages. Evidence copies
are qemu-result.json and qemu-usb-fallback-result.json under the same userspace
artifact directory. The latter exercises fallback only, not real USB switching.

No MiBOX boot image has been repacked or flashed. Independent boot still needs
a verified image acceptance and software recovery path; hardware modification
is not an owner requirement.
