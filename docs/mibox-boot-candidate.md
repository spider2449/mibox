# First stock-kernel custom-system candidate

Status: NOT READY TO BOOT OR FLASH. This is a locally assembled, independently
parsed candidate. It has not been uploaded to the box or accepted by its loader.

## Artifacts

| Artifact | Bytes | SHA256 |
| --- | --- | --- |
| target/mibox-rootfs/initramfs.NOT_READY.cpio.gz | 706467 | 5615e553b50a21fee0d11ab8926831eb1f21ab588911cb423d8f0f859ba5e8bd |
| target/mibox-boot-candidate/boot1-custom.NOT_READY.img | 8388608 | f05adbc3d79c8f41be7fef1145f6111f436d35921b7051722ae5195ae7624bba |

Provenance and independent layout evidence are copied under
artifacts/mibox-rootfs/2026-11-14/ and artifacts/boot-candidate/2026-11-14/.

The image uses the verified boot1 backup as its header/kernel/DTB template.
The original kernel uImage and 11414-byte DTB are byte-for-byte unchanged.
Header command line, page size and load addresses are preserved. Only ramdisk
size and Android image ID header fields change; ramdisk content is replaced
with the custom rootfs. Remaining partition bytes are zero, matching the
measured zero-tail layout. No unclassified recovery tail was used or stripped.

The builder first verifies the original 8 MiB backup SHA256, installed-script
prefix, section bounds, Android ID and zero tail. Its output is restricted to
this workspace's target directory. It recomputes the section-based Android ID
and uses the existing independent inspector to verify new section readbacks.

An additional run of extract-stock-boot.py on the generated image independently
validated the new Android ID, decompressed newc archive/trailer and DTB size.
The kernel and DTB extracted from the candidate match the original hashes.
The stock prefix hash intentionally differs: this is not an official OTA image,
and an image ID is not a signature or proof of bootloader acceptance.

## RAM system contents

- Custom Rust /init and /bin/mibox; custom /etc/os-release.
- Unmodified static stock recovery /sbin/adbd and /system/bin/sh.
- /bin/sh symlink, virtual-filesystem directories and /dev/console.
- One authorized public key from this Windows host's adbkey.pub, normalized
  without its original hostname comment. No private key or QEMU test probe.
- Read-only /etc/mibox-usb-adb.enabled explicitly enables the authenticated
  USB startup path. This avoids relying on unknown header-cmdline handling.

The shared property-area builder is tested with the same full eight-property
set used by the candidate. Stock adbd verifies a cached public key and executes
the custom toolbox as UID2000 in QEMU. A bad signature is rejected first.

USB setup is restricted to custom PID1, an explicit flag or trusted rootfs
marker, the stock compatible string AMLOGIC,8726_MX, required gadget attributes
and trusted key/binary file metadata. The compatible string is a SoC/platform
guard, not proof of a unique physical motherboard identity. No live Android
session is reconfigured. A detected Android settings binary is refused.

After preflight, the fresh-boot setup uses the observed stock FunctionFS recipe,
VID/PID 18d1:d002 and the owner's existing serial. It enables public-key auth,
keeps secure UID2000 behavior, and supplies zero TCP-port properties. It refuses
to spawn adbd without the FunctionFS ep0 endpoint, preventing the daemon's
no-USB TCP fallback. Failures attempt to restore the snapshot of USB attributes.
That hardware setup/restoration path is NOT hardware-tested.

## Validation and limits

The candidate rootfs itself passed 10/10 generic-QEMU console stages. Without
adding a kernel USB flag, its rootfs marker requests ADB; the platform guard
correctly rejects QEMU before gadget setup and retains the console. The same
shared property builder/full property set passed 11/11 authenticated ADB shell
stages in the separate QEMU test rootfs. These are not stock-kernel PID1 or
physical USB transport tests.

The physical MiBOX still runs its stock Android, with the reboot-verified V3 ADB
hook. system/system1 snapshots and original named boot backups are preserved.
The separate failed hardware-boot0 partial read is not a usable recovery image.

Remaining gates: actual FunctionFS console, loader acceptance and a verified
software-only return path. No UART modification is required by the owner.
No flash/upload command is provided by the builders.

## Reproduce locally

```powershell
cargo build --release --bin mibox-init --bin mibox-userland
wsl python3 /mnt/f/coding/otherPrj/mibox/scripts/build-mibox-rootfs.py --adb-public-key /mnt/c/Users/morefunfun/.android/adbkey.pub --enable-usb-adb --output /mnt/f/coding/otherPrj/mibox/target/mibox-rootfs
wsl python3 /mnt/f/coding/otherPrj/mibox/scripts/build-mibox-boot-candidate.py --output /mnt/f/coding/otherPrj/mibox/target/mibox-boot-candidate
wsl python3 /mnt/f/coding/otherPrj/mibox/scripts/test-init-qemu.py --rootfs-usb-adb-marker --initramfs /mnt/f/coding/otherPrj/mibox/target/mibox-rootfs/initramfs.NOT_READY.cpio.gz
```
