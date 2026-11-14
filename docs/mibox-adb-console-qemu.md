# Stock ADB console with custom userspace: QEMU proof

The exact stock recovery adbd and shell now execute the custom Rust toolbox
successfully in an isolated generic ARM QEMU guest. The complete PID1 console
test passed 11/11 stages. This establishes userspace/ADB protocol compatibility;
it does not establish physical USB FunctionFS transport or MiBOX independent boot.

Follow-up authenticated mode also passed 11/11: the daemon rejects an invalid
RSA signature, issues another challenge, then accepts a valid signature made
by a dedicated host-only test key. The guest contains only the public key.
Normal and missing-flag guard cases were rerun against the current init/probe
and also passed 11/11 each.

QEMU has no virtual NIC, host port forwarding or persistent disk. The test uses
only guest loopback. No live box USB configuration was changed or tested.

## Failure, diagnosis and fix

The first run reached the custom init console but stock adbd died with SIGSEGV.
The stock shell independently executed /bin/mibox correctly, narrowing the fault.
A bounded ptrace diagnostic inside the QEMU-only probe captured:

```
pc=0x1f6fe fault=0x90 r6=0x80
ldr r3, [r6, #16]
```

This is consistent with the missing Android shared property area's root node.
The Android 4.4 [bionic property implementation](https://raw.githubusercontent.com/aosp-mirror/platform_bionic/android-4.4.2_r1/libc/bionic/system_properties.c)
maps a property area and accesses the root node through its global pointer,
including when a requested property does not exist. The
[ABI header](https://raw.githubusercontent.com/aosp-mirror/platform_bionic/android-4.4.2_r1/libc/include/sys/_system_properties.h)
defines its magic/version and /dev/__properties__ path. The probe now creates
a root:root, 0444, 128 KiB empty area with a 128-byte header and 20-byte root
node in QEMU RAM before executing adbd. No real Android properties are copied,
changed or spoofed. Repeating the test after this initialization removes the
crash and reaches the shell command, supporting the diagnosed dependency.

The unmodified Android 4.4 [ADB daemon defaults](https://raw.githubusercontent.com/aosp-mirror/platform_system_core/android-4.4.2_r1/adb/adb.c)
allow its TCP fallback when USB endpoints are absent. This test's empty area
does not supply authentication properties. It is the baseline compatibility
case. The authenticated case instead supplies ro.adb.secure=1 and ro.secure=1
in the same read-only ABI, and the dedicated public key at /adb_keys.
Neither case changes authentication on a real device.

The [stock authentication flow](https://raw.githubusercontent.com/aosp-mirror/platform_system_core/android-4.4.2_r1/adb/adb_auth_client.c)
loads authorized keys from /adb_keys and verifies token signatures. The test
formats its generated public key according to the
[AOSP RSA public-key structure](https://raw.githubusercontent.com/aosp-mirror/platform_system_core/android-4.4.2_r1/include/mincrypt/rsa.h).
It first sends an invalid 256-byte signature and requires another AUTH challenge.
The QEMU probe then prints that token over its serial console. The host harness
uses OpenSSL to sign the token with the disposable key and returns the signature
over serial; the guest forwards it as an ADB AUTH response. Only CNXN following
that response allows the shell test to proceed. No framework confirmation UI,
owner private key, verifier patch or authentication bypass is involved.

## What passed

- /init reports PID1; ordinary console/toolbox stages remain functional.
- Stock shell executes the custom statically linked toolbox.
- Probe starts stock recovery adbd and exchanges checksummed ADB CNXN packets.
- OPEN requests shell:/bin/mibox info; WRTE/OKAY/CLSE stream handling completes.
- Response identifies mibox-custom, the guest kernel and UID/EUID 2000.
- The probe kills/waits for its daemon. PID1's independent reaptest then passes.
- Unknown commands and long-input console recovery still pass.

Evidence: artifacts/qemu-adb/result.json, console.log and
initramfs-provenance.json. Earlier failed transcripts are retained separately,
including attempt-3-ptrace-console.log. The tested rootfs is
target/qemu-adb/initramfs.cpio.gz, explicitly QEMU-only.
Authenticated artifacts are under artifacts/qemu-adb-auth/, with their own
initramfs provenance. The private test key stays under ignored target/ and is
never copied into a rootfs or evidence directory. qemu_adb_key.py uses only
OpenSSL and Python's standard library; no runtime crypto dependency was added
to the custom ARM toolbox.

## Guard checks

Before creating files, mounting devpts or configuring loopback, the probe
requires BOTH exact kernel token mibox.test_adb=1 and compatible=linux,dummy-virt.
It additionally refuses the presence of the Android USB gadget sysfs directory.
It is not deployed to the box.

A separate 11/11 test boots the same image without the required flag. The probe
refuses before property initialization or daemon handshake; ordinary PID1 and
reaper stages still pass. Evidence: artifacts/qemu-adb-guard/.

## Reproduce

```powershell
cargo build --release --bin mibox-init --bin mibox-userland --bin mibox-adb-probe
wsl python3 /mnt/f/coding/otherPrj/mibox/scripts/build-qemu-initramfs.py --with-stock-adb
wsl python3 /mnt/f/coding/otherPrj/mibox/scripts/test-init-qemu.py --timeout 45 --test-stock-adb
wsl python3 /mnt/f/coding/otherPrj/mibox/scripts/test-init-qemu.py --timeout 45 --test-stock-adb-guard
wsl python3 /mnt/f/coding/otherPrj/mibox/scripts/build-qemu-initramfs.py --with-stock-adb-auth
wsl python3 /mnt/f/coding/otherPrj/mibox/scripts/test-init-qemu.py --timeout 45 --test-stock-adb-auth
```

The builder pins the extracted adbd/sh hashes and records every added binary's
hash. Missing prerequisites fail rather than downloading replacement firmware.
To regenerate stock binaries, use inspect-stock-recovery.py with its fixed
--binaries-output option against the existing verified recovery cpio.

## Independent boot remains separate

The remaining USB console work is provisioning the owner's public keys in a
hardware-targeted rootfs and testing actual FunctionFS transport under the
stock kernel. The protocol's cached-key verification now has QEMU evidence.
Image acceptance and a verified
software return path are still open. Do not flash this generic QEMU initramfs
or treat loopback ADB as proof that those hardware boot gates passed.
