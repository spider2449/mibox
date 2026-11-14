# Rust PID1 QEMU validation

The actual ARMv7 static mibox-init binary booted as PID 1 in qemu-system-arm.
The latest automated console test passed all 10 stages, including custom
userspace identity and root listing. Normal and absent-gadget fallback both
passed. Earlier 8-stage evidence is retained in artifacts/qemu-history/pre-userland.
This is generic ARM validation,
not a MiBOX1S hardware boot or a test of the stock 3.10.33 kernel.

Earlier follow-up: init passed all 8 original stages with mibox.usb_acm=1
requested on the generic machine, exercising fallback to /dev/console when
the Android gadget attributes do not exist. The latest console.log/result.json
record this case; console-baseline.log/result-baseline.json retain the original
non-USB run. The test still does not exercise real gadget configuration.

## Tested behavior

1. Kernel launched /init; init mounted proc, sysfs and devtmpfs, started its
   reaper thread and reached MIBOX_INIT_CONSOLE_READY.
2. help listed console commands.
3. info reported pid=1 and arch=arm.
4. uptime returned a numeric uptime and idle time.
5. reaptest spawned /init as an ordinary child. PID1's separate waitpid loop
   collected that specific child, reporting REAP_OK. Child::wait was not used.
6. An unknown command returned a useful response.
7. A 300-byte input line exceeded the console's bound, then console service
   restarted without PID1 exiting.
8. info still reported pid=1 after that recovery.

The first harness run timed out while expecting uptime at the start of a line;
the actual program had returned it after a prompt. The harness was corrected to
wait for each complete response and following prompt before sending more input.
The first log/result are retained separately; the final run passed all stages.

## Test environment and provenance

- QEMU 8.2.2 on WSL Ubuntu-24.04, machine virt, CPU cortex-a15, 256 MiB RAM.
- Debian generic ARM kernel 6.12.107+deb13-armmp.
- Kernel acquired from
  https://deb.debian.org/debian/dists/stable/main/installer-armhf/current/images/netboot/vmlinuz
  and verified against the same installer's official SHA256SUMS, downloaded over
  HTTPS. Expected and actual SHA-256:
  b508abca3127cb0d9e1b3aba37f400cbd7dac170040641756807e0e496039de8.
- No Mi Box kernel or DTB was substituted into this virtual machine. QEMU's
  generic device tree and PL011 UART are distinct from the box's Amlogic UART.
- No virtual persistent disk or network interface was attached.

The QEMU-only initramfs contains init, /bin/mibox, /etc/os-release,
proc/sys/dev/bin/etc/tmp directories and /dev/console.
It is deterministic and has no Android boot header or vendor firmware packaging.
It must not be flashed as a boot partition image.

## Reproduce

With the verified generic kernel at phone-tools/qemu/vmlinuz and the installed
ARMv7 Rust target / qemu-system-arm:

```powershell
cargo build --release --bin mibox-init --bin mibox-userland
wsl -d Ubuntu-24.04 -- python3 /mnt/f/coding/otherPrj/mibox/scripts/build-qemu-initramfs.py
wsl -d Ubuntu-24.04 -- python3 /mnt/f/coding/otherPrj/mibox/scripts/test-init-qemu.py
```

Add --request-usb-acm to the final command to test the no-gadget fallback case.

The test terminates only its own QEMU process when finished. It does not access
ADB, bootloader state or raw Mi Box partitions. No additional packages were
installed in WSL for this test.

## Evidence

- artifacts/qemu/console.log: full successful boot/console session.
- artifacts/qemu/result.json: latest 10/10 passed, no failure, exact QEMU arguments.
- artifacts/qemu/initramfs-provenance.json: hashes for the tested init binary,
  uncompressed cpio and compressed initramfs.
- artifacts/qemu/kernel-provenance.json and rustc.txt: input/compiler identity.

Remaining hardware gates: reachable UART or tested USB ACM console, verified
nonpersistent loader/recovery path, and stock-kernel watchdog handoff behavior.
QEMU success does not satisfy those gates or demonstrate stock-kernel ABI
compatibility for all PID1/thread/process-management syscalls.

The additional os/files commands execute custom static /bin/mibox. Explicit
child waits and the background reaper share a mutex, avoiding status collection
by the wrong waiter. Both new commands and the existing reaptest passed.
