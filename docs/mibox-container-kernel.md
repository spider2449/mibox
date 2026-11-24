# Meson6 container kernel development, 2026-11-15

2026-11-21: [atomic-context fixes](mibox-kernel-atomic-context.md) address
the timer IRQ, A9 clock and Ethernet allocation diagnostics found in the
Dev10 startup log. Dev11 passed the targeted RAM tests; Dev12 adds automatic
IPv4 default-route recovery (RAM-verified 2026-11-24). Dev10 remains installed.

Two kernels have been cross-built: the recovered-stock-configuration hardware
baseline and development build tag `3.10.99-mibox-container-dev+`. The BSP exposes
the short `UTS_RELEASE=3.10.99` through uname and /proc/version, while its boot
banner uses `UTS_RELEASE_FULL`. The development configuration passes the legacy
cgroup-v1/VFS feature audit. **The new kernel has booted on the physical MiBox.**
Primitive and software-return validation is recorded separately below.
No Docker engine compatibility or production readiness is claimed by a build.

**Physical result: PASS for temporary kernel boot, the six primitive diagnostics
and software return to completed Android.** The box is back on stock Android.
Machine-readable verdict: `artifacts/kernel-meson6/2026-11-15/summary.json`.

## Source and hardware basis

- [codesnake/linux-amlogic](https://github.com/codesnake/linux-amlogic/tree/8b1bb2b31a8e94b773a4b8ab907a0473a0951192),
  commit `8b1bb2b31a8e94b773a4b8ab907a0473a0951192`, Linux 3.10.99.
- The Meson6 machine description accepts the stock `AMLOGIC,8726_MX` string.
  It includes Meson6 clock, pinmux, Ethernet, MMC, HDMI/audio and the vendor USB
  gadget implementation. Driver source presence does not establish operation.
- The raw 11414-byte stock DTB is retained unchanged, SHA256
  `24b30f1aafe26845839966721b3c083cb3ed49280178276b6114df6d725cb95c`.
- This is a reference BSP, **not** Xiaomi's exact `g9f9cb70` source. Configuration
  differences are recorded in each build manifest. No replacement board DTS
  or guessed register values were introduced.

`scripts/audit-meson6-source.py` models the pinned `drivers/of/fdt.c` algorithm
against the raw DTB. Its output matches the saved physical `/proc/iomem`:

| Start | Inclusive end | Type |
| --- | --- | --- |
| 0x80000000 | 0x84ffffff | System RAM |
| 0x85000000 | 0x8defffff | Video RAM |
| 0x8df00000 | 0x9fefffff | System RAM |
| 0xa0000000 | 0xbfffffff | System RAM |

The reversed `aml_reserved_end=0x84000000` and `aml_reserved_start=0x85000000`
describe an additional RAM bank before the low reservation pool in this parser.
The seven reservation nodes allocate 142 MiB, plus 1 MiB DSP reservation.
The source also excludes 0x9ff00000..0x9fffffff for firmware. The audit depends
on Meson6, disabled TrustZone, the exact stock DTB and this pinned algorithm;
it is not a general-purpose DT converter.

## Build changes

`kernel/patches/0001-meson6-build-fixes.patch`:

1. Share one ramoops context structure, including its `memtype` field, between
   the driver and vendor pstore consumers. Preserve pstore support.
2. Use typed UID comparisons in the CPU cgroup permission check.
3. Use typed global UID comparisons for the vendor Android oom_adj permission
   exception, so enabling user namespaces compiles without raw UID conversions.

`kernel/meson6-bsp-build.config` enables SW_SYNC, required by this source's OSD
driver, and disables raw NAND/MTD that the public BSP otherwise newly enables.
The physical box uses eMMC and its recovered stock configuration has MTD off.
Display and audio are retained. The host dtc is built with `-fcommon`; the ARM
linker is the pinned toolchain's `ld.bfd`, avoiding gold's EXIDX layout warnings.
Remaining vendor-source warnings are preserved in `build.json` and build logs.

`kernel/meson6-containers-v1.config` enables PID/UTS/IPC/network/user namespaces,
veth, bridge/NAT support, seccomp filtering, kernel keys, tmpfs xattrs and cgroup
v1 resource controllers. Android paranoid networking, low-memory killer,
QTAGUID and QUOTA2 are disabled for this dedicated Linux userspace profile.
The Android traffic-accounting implementations are not userns-aware in this BSP.

This kernel does **not** implement cgroup v2, overlayfs or the pids controller.
The pi2-os Rust-native engine cannot run unchanged. A Docker engine version,
runtime and VFS storage configuration still need separate compatibility tests.
Docker documents [VFS storage](https://docs.docker.com/engine/storage/drivers/vfs-driver/)
as a full-copy storage driver; it has different performance/space requirements
from overlay2. Its existence alone does not verify an engine on this board.

## Reproduce

Source, build directories and the pinned Android GCC 4.9 compiler live on WSL
Linux storage at `/home/morefunfun/.cache/mibox-kernel`. The compiler is pinned
to `111258a10e017f067b27e6cfcea7619d753f3309`. Other projects' source trees and
toolchains are not changed. Preparation checks the entire local source diff
against the checked-in patch and refuses unrecorded changes.

```powershell
wsl -d Ubuntu-24.04 --exec bash /mnt/f/coding/otherPrj/mibox/scripts/build-mibox-kernel.sh baseline
wsl -d Ubuntu-24.04 --exec bash /mnt/f/coding/otherPrj/mibox/scripts/build-mibox-kernel.sh containers-v1
```

Exports: `target/kernel-meson6/{baseline,containers-v1}/{zImage,Image,System.map,resolved.config}`.
Reports and ELF headers: `artifacts/kernel-meson6/2026-11-15/`.
The recorder checks ARM32 ELF and zImage headers, finds the kernel banner,
decompresses the built LZMA payload and compares it with Image, checks export
hashes, and verifies that source/configuration did not change while building.

The development `Image` SHA256 is
`67fab7090121e9f0f819c6f0d4d3ff6184172ddbd36793928c4f2cd178f1a2c5`;
the resolved config SHA256 is
`ace17f68a0d1d0c9084dae437d8456b6719fcb720b43b92f6295951c4c67ab5c`.

Host validation passed: five configuration-gate tests, two exact development
guard tests with the feature enabled and again with it disabled, five local
image/action rejection cases, and both generic-QEMU restart/guard scenarios.
These do not count as board tests. The build targets zImage, not a complete
module installation; selected Wi-Fi/GPU modules are not established by it.

## Dedicated RAM experiment

The `container-kernel-test` Cargo feature builds an isolated init at
`target/kernel-userspace`. It accepts the exact development release plus a
read-only rootfs marker; ordinary builds retain the original stock guard.
The runtime comparison uses the BSP's short release `3.10.99`; the marker retains
the full development tag and pinned source commit. Host checks bind the actual
running embedded config and uploaded image to the build, rather than treating
the short version string as proof of source identity.
The root helper is restricted to that release, marker, stock compatible string,
root credentials and PID1 as parent. It performs diagnostics in private mount
and network namespaces and does not mount a block filesystem.

Diagnostics cover namespace creation and PID1, an isolated veth pair and bridge,
tmpfs mount, preservation of the parent's UTS/network state, user namespace,
seccomp enforcement, and cgroup memory/CPU limit write/readback. Limit readback
does not prove workload accounting or OOM/CPU throttling under load.

`scripts/build-meson6-boot-test.py` retains stock Android header addresses and
DTB, and wraps the newly built Image in the stock ARM/Linux/LZMA uImage format.
The LZMA header matches stock, including its 8 MiB dictionary. uImage checksums,
decompression, independent Android image section hashes and Android ID pass.
This is a RAM experiment, not an installation image or signed firmware.

Current candidate (ContainerKernel2) SHA256:
`fb1333d9d36c92577ef17643590f67cea596e7d76df33ff8238aa7fcb192f6a6`.
The image is 8388608 bytes; aligned used content is 5146624 bytes. Its uImage
loads at the verified 0x80008000 address and expands below 0x82000000.
`System.map` additionally places the end including BSS at 0x80d8baf8 after
translation relative to `_text` and that uImage load address.

```powershell
powershell -NoProfile -File scripts/Test-ContainerKernel.ps1 -Action Check
```

`Check` is local-only. The separately authorized `RoundTrip` requires completed
stock Android, enters the known C003 loader, uploads and fully verifies all
8 MiB before a fixed `bootm 0x82000000`. It then checks the actual kernel
release, fresh boot ID, pulled userspace hashes, running embedded config hash,
diagnostic results and independent Android return. No persistent flash command
is present in this workflow. The owner confirmed physical power recovery is
available for this first replacement-kernel test.

## First physical trial and version correction

Evidence: `artifacts/kernel-meson6/physical-20261115-113421/confirmed-boot.json`
and `runtime-inventory.txt`. All 8 MiB of candidate ContainerKernel were verified
with SHA256 `dce6ac31ab47bce5dfee987cfd1cac1b40f9e200bd2d953f768113c77563e35e`
before bootm. The new boot ID was `563ca15e-69e3-4a1a-ad6b-aef0828d499c`.
USB ADB, custom root PID1 and its userspace returned under kernel 3.10.99.
Pulled /init and /bin/mibox matched the candidate; the actual /proc/config.gz
decompressed to the exact built config hash above. The runtime memory banks
matched the source model, MemTotal was 876552 KiB, and eth0 registered with the
expected MAC. Network connectivity, HDMI and audio were not tested on this boot.

The first harness and init guard incorrectly expected the full development tag
from uname. The harness therefore stopped, and the helper/restart guard did not
run. This was a test-userspace version mismatch, not a failed kernel boot.
The owner then power-cycled back to Android, independently observed with new
boot ID `41cad27c-ceb6-4bd7-a4c2-6a8d6869dc95` and boot_completed=1.

ContainerKernel2 keeps the **identical kernel uImage** and stock DTB, correcting
only the guarded test userspace's runtime-version expectation. Its second
physical trial is `artifacts/kernel-meson6/physical-20261115-122806/`.

## Second physical trial: PASS

The complete 8388608-byte ContainerKernel2 image was written and read back using
the 64-byte control channel; its full SHA256 matched before bootm. New kernel
boot ID: `8e7bf0c1-212a-4e2e-8eb6-e7a616fdd217`. Pulled userspace hashes and
the actual embedded kernel configuration matched the candidate and build.

`physical-20261115-122806/kernel-selftest.txt` records:

| Diagnostic | Physical result |
| --- | --- |
| PID/UTS/IPC/network/mount namespaces, PID1, veth, bridge and tmpfs | PASS |
| Parent UTS/network state unchanged | PASS |
| User namespace creation | PASS |
| Seccomp syscall denial | PASS |
| Memory cgroup limit write/readback | PASS |
| CPU cgroup quota write/readback | PASS |

The exact new init's guarded restart service accepted one normal restart.
Independent observations confirmed the original Android fingerprint,
boot_completed=1 and new Android boot ID
`26fbc60a-d5ec-48fb-88ec-26177c61f961`. Return evidence:
`artifacts/software-return/return-20261115-125016/`.
No manual power recovery was needed for this second round trip.

The verdict is for this exact RAM candidate and tested primitives. No Docker
daemon/image workload, published network port, resource-limit load test,
new-kernel Ethernet connectivity, HDMI/audio or persistent Linux installation
was validated. cgroup v2, overlayfs and pids limits remain unavailable in this
BSP; the pi2-os native engine still requires a different kernel route.

Subsequent work on the identical kernel has now passed a
[physical offline Docker workload and Android return](mibox-docker-runtime.md#second-physical-trial-offline-container-pass)
using the separate DockerKernel2 RAM userspace. The engine report retains both
the failed initial sandbox trial and the corrected passing trial. Persistent
services, registry pull, physical container networking and peripheral validation
remain separate gates.
