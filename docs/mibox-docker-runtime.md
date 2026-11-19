# Docker containers on MiBox, 2026-11-15

Status: **physical offline Docker container test PASS on the replacement
kernel**; **NOT READY on the recovered stock kernel**. The goal is device-side
containers managed from the PC, as in pi2-os. Persistent service integration,
registry pull, bridge/NAT/published ports and authenticated remote API remain
outstanding.

Update: a replacement [Meson6 development kernel](mibox-container-kernel.md)
has now passed physical RAM boot, six container primitive diagnostics and
software return to Android. It enables a legacy cgroup-v1/VFS development path;
it does not supply the cgroup-v2/overlay requirements of pi2-os's native engine.
Docker 24.0.9 now runs an offline ARMv7 workload in a temporary private RAM
environment. Complete persistent service integration remains outstanding.

## Reference design

Inspected upstream files on 2026-11-15:

- [pi2-os README](https://github.com/spider2449/pi2-os/blob/master/README.md):
  Rust PID1/supervisor, engine services, persistent container data and remote
  Docker CLI access over mTLS.
- [Docker engine](https://github.com/spider2449/pi2-os/blob/master/crates/pios-engine-docker/src/lib.rs):
  containerd followed by dockerd, readiness checked using `/_ping` on the Unix
  socket, restart policy and orderly shutdown, overlay2, bounded local logs.
- [Native runtime](https://github.com/spider2449/pi2-os/blob/master/crates/pios-engine-native/src/runtime.rs):
  Docker API compatibility without dockerd; still uses real Linux namespaces,
  overlay mounts, pivot_root and cgroup2. This does not bypass kernel needs.
- [Kernel fragment](https://github.com/spider2449/pi2-os/blob/master/kernel/pios.config):
  namespaces, resource controllers, overlayfs, veth/bridge/netfilter and seccomp.

These are mutable upstream links. This audit does not vendor or execute their
code. The Pi's BCM2836 kernel, firmware, DTB and SD partition scheme cannot be
used as the MiBox casablanca/Meson6 board port. Keep MiBox HDMI/audio support;
do not copy pi2-os's sound/DRM removal choices.

## Local evidence

Input: `artifacts/platform/2026-11-14/stock-kernel.config`, recovered from the
stock kernel, SHA256
`bd2a94b6aa84afda30661c3a4b41f9759fcc6734ee32daf8335882ba6b43c918`.
Version header: Linux/arm 3.10.33.

| Feature | Recovered setting | Effect |
| --- | --- | --- |
| Namespace umbrella | CONFIG_NAMESPACES=n | Hard blocker for isolated container processes |
| Network pairs | CONFIG_VETH=n | Reference bridge network unavailable |
| Syscall filter | CONFIG_SECCOMP=n | Reference filtering unavailable |
| Kernel keys | CONFIG_KEYS=n | Reference profile incomplete |
| tmpfs xattrs | CONFIG_TMPFS_XATTR=n | Reference storage profile incomplete |
| cgroups, memory, CPU | Several controllers=y | Does not establish cgroup v2 or engine compatibility |
| Overlayfs, PID controller, namespace child keys | UNKNOWN where absent | No inferred disabled values or backport claims |

The namespace blocker alone rules out both reference engines under this stock
kernel. A chroot, Docker CLI installation or static dockerd binary cannot add
the missing kernel implementation. pi2-os's native engine requires cgroup v2;
the recovered 3.10 version and cgroup-v1 options do not establish its presence.

The official [MiCode source index](https://github.com/MiCode/MiBox_Kernel_OpenSource/blob/README/README.md)
was checked again and lists MIBOX3(global), once-o-oss. It does not identify a
matching casablanca source. This limited search does not prove that matching
source is unavailable everywhere. Board-specific replacement-kernel readiness
remains UNKNOWN; see [existing kernel/source analysis](mibox-software-boot-analysis.md).

## Reproduce the offline gate

From the repository root on Windows with this project's WSL distribution:

```powershell
wsl -d Ubuntu-24.04 --exec python3 /mnt/f/coding/otherPrj/mibox/scripts/check-container-kernel.py --output /mnt/f/coding/otherPrj/mibox/artifacts/docker-runtime/2026-11-15/stock-kernel-audit.json
```

On a Python-equipped host use `python3 scripts/check-container-kernel.py`.
Exit 1 means the selected configuration profile did not pass. Malformed input
raises an error. Explicit disabled options are `n`; missing keys stay UNKNOWN;
modules stay UNKNOWN until matching modules and loading are demonstrated.
The generated JSON includes config hash and source line numbers.

This is a conservative profile audit, not the Docker upstream check-config tool
or a complete kernel compatibility test. Some options change between kernel
versions (including devpts); evaluate those against the selected source tree.
Even a config gate PASS leaves runtime readiness NOT READY until boot, cgroup2,
storage, engine and physical container checks are completed.

Validation: `scripts/test-container-kernel.py` passed 4 host tests under WSL
Python on 2026-11-15, covering unknown/module handling, contradictory/empty
inputs, config-only false readiness and the hash-pinned stock blocker.
The actual stock audit exited 1 as expected. These are host checks only.

## Implementation sequence and acceptance

1. Establish a casablanca kernel source/board port. Prefer a maintainable kernel
   supporting the selected engine and cgroup v2; an old BSP would require a
   separate backport/engine compatibility assessment. Verify RAM layout, USB
   recovery, Ethernet, storage and HDMI/audio against this board. Do not merge
   the Pi fragment blindly or fabricate a board DTS.
2. Build that kernel, inspect its final resolved config and artifacts, then
   prove temporary RAM boot and the existing software return path. A generic
   QEMU boot cannot satisfy the board gate. Do not install a default boot image
   merely because the configuration audit passes.
3. Start with dockerd/containerd/runc as the reference correctness target;
   pin ARMv7 binaries and hashes after kernel compatibility is established.
   Consider the Rust-native engine later if measured memory savings justify
   its API and runtime maintenance. The development candidate below is selected;
   physical engine compatibility remains unverified.
4. Integrate PID1 supervision and graceful stop, use a dedicated persistent
   container-data directory with verified filesystem features and free space,
   set up bridge/NAT, clock synchronization and CA certificates. Validate the
   local Unix socket before exposing mTLS on port 2376. Keep certificate
   identity consistent with the PC's Docker context.
5. On the actual MiBox, pull a pinned linux/arm/v7 image and prove `run --rm`,
   `exec`, logs, stop/remove, bridge DNS and a published port. Prove memory/PID
   limits and a named volume surviving engine restart and a controlled reboot.
   Record kernel/engine/image versions, hashes, commands and results. Only then
   mark device-side container operation PASS.

The initial audit made no device changes. Subsequent kernel RAM experiments,
including their exact scope and physical evidence, are recorded in the linked
kernel development report.

## Prepared legacy engine experiment

Docker **24.0.9**, official `armhf` static archive, is selected for an initial
compatibility experiment. This historical version is not a production support
or security claim. Its [official release notes](https://docs.docker.com/engine/release-notes/24.0/)
record Go 1.20.13 and runc 1.1.12. The actual downloaded bundle reports
containerd 1.7.13, runc 1.1.12 (libseccomp 2.5.1), and tini 0.19.0.
Docker's [binary installation prerequisites](https://docs.docker.com/engine/install/binaries/)
include kernel 3.10 or later; satisfying a version floor does not establish
compatibility with this vendor BSP or all bundled runtimes.

Archive: `https://download.docker.com/linux/static/stable/armhf/docker-24.0.9.tgz`.
SHA256: `630150b66241a8e9aac29a8414b88cbeed94f39e306c5bac5f934f231639cc42`.
The pin was established from the first HTTPS download, not an independently
verified publisher signature. All eight extracted binaries are little-endian
ARM ELF32 with no dynamic loader or dynamic segment. Their individual sizes
and hashes are recorded in `artifacts/docker-runtime/2026-11-15/docker-payload.json`.

Reproduce on WSL using a new output directory:

```sh
python3 scripts/test-docker-payload.py
python3 scripts/prepare-mibox-docker.py --output /home/morefunfun/.cache/mibox-docker-24.0.9-ram-test
```

Preparation refuses a changed archive, extra/duplicate/unsafe tar members,
non-ARM executables and dynamic dependencies before executing version probes.
It does not overwrite an existing output directory. All six QEMU version
probes and `dockerd --validate` passed; four ELF guard tests passed. QEMU uses
the host kernel here and cannot validate the target kernel's syscall behavior.
No daemon was started and no payload was deployed to the box by this step.

The generated `daemon-ram-test.json` selects VFS and cgroupfs, bounded logs,
paths under `/run/mibox-docker-test`, and a Unix socket only. The first gate
disables bridge, iptables, forwarding and masquerading so an offline container
can establish engine/runtime operation before changing physical networking.
Published ports, registry pull, persistent data and PID1 supervision are still
separate outstanding gates. The existing ContainerKernel2 boot image contains
neither Alpine nor Docker; a separately staged RAM userspace and clean mount/
process teardown are required before another physical trial.

## Offline RAM experiment implementation

The `DockerKernel` candidate retains ContainerKernel2's kernel uImage, stock DTB,
PID1 and `/bin/mibox` byte-for-byte. Its rootfs adds the previously tested Alpine
BusyBox/musl and the fixed `mibox-console-start` hook. This hook waits for an
authenticated ADB upload, copies it into root-owned RAM, and verifies a built-in
SHA256 before extraction. No general privileged execution endpoint was added.

The static C supervisor creates private mount, network, UTS, IPC and PID
namespaces, and extracts the exact payload into a separate 384 MiB tmpfs.
It moves that tmpfs onto the private namespace root and changes its PID1's root
to match. This matters for runc: plain chroot left `docker exec` unable to open
`/proc/self/fd`; initramfs rootfs also rejects pivot_root. The move does not
unlink any files from the original RAM rootfs. Child mounts include proc,
read-only sysfs, a private device tmpfs/devpts, and cgroup-v1 controllers.
No block devices or physical network interfaces are exposed in this test.
The parent kills the namespace leader after 240 seconds if necessary, which
destroys the remaining descendant processes. Namespace mounts disappear when
the supervisor exits. Main PID1 and authenticated USB ADB remain outside it.

The offline image is built locally from the same fixed ARM BusyBox/musl;
its input tar SHA256 is
`0e020f2866404ac357e96413631785726242bc03792b2bf8873f770b54c2ee0c`.
Docker imports it, runs it with `--network none --memory 32m --cpus 0.5 --init`,
checks `Seccomp: 2` in the container, executes a second command, retrieves logs,
stops and removes it. This tests configuration of resource limits; workload
accounting, OOM enforcement and CPU throttling remain separate tests.

Host validation passed in `artifacts/docker-runtime/qemu-offline-20261115-134609/`.
It uses the same sandbox implementation with a separately compiled QEMU-only
board/release guard; the builder rejects that guard in the physical payload.
The QEMU kernel comes from Debian bookworm's
`https://deb.debian.org/debian/dists/bookworm/main/installer-armhf/current/images/netboot/vmlinuz`,
SHA256 `1ae18b60e4720ef744afac6fb51d18a1cd377521072dab55772c2fc09ed290d4`,
checked against the distribution's `images/SHA256SUMS` over HTTPS.
The previous Debian 6.12 fixture lacks MEMCG_V1/CPUSETS_V1 and failed this
profile. Other failed root-transition trials are retained alongside the pass.
These host results do not establish MiBox kernel compatibility.

Build/check commands from WSL and then Windows:

```sh
bash scripts/build-docker-sandbox.sh
python3 scripts/build-docker-experiment.py
python3 scripts/test-docker-experiment-qemu.py
python3 scripts/build-meson6-boot-test.py --rootfs target/mibox-rootfs-docker --output target/mibox-boot-candidate-docker
```

```powershell
powershell -NoProfile -File scripts/Test-DockerExperimentGuards.ps1
powershell -NoProfile -File scripts/Test-MiboxDocker.ps1 -Action Check
```

`Check` is local-only; `RoundTrip` performs actual USB loader RAM boot, full
8 MiB readback, running config/userspace verification, payload upload and
readback, offline workload, parent mount/process cleanup checks and independent
Android return. Image SHA256:
`3d0be1a75f59e1ecd21459768b603cef8c3c769e0e31f69445d68cf34bf3f2dc`.
Payload SHA256:
`33bba141e73e1a296f1c3bb425c8df2cd20593656275ecdfaa417dcc9824b880`.

The first physical trial (`physical-20261115-134811`) passed image/payload
readback, config/userspace identity, cleanup and normal Android return, but
failed before starting dockerd: the vendor 3.10 kernel rejected a redundant
recursive bind of the original rootfs (`EINVAL`). This failure is retained.
`DockerKernel2` removes that bind and preserves the same tmpfs root transition.
Its image SHA256 is
`13794e4423287cc12ea2b63bff22a937b156d70d54fb4141ba9342ea4b19c1fa`.
All kernel/DTB/init/userland and external payload bytes remain identical.
The corrected helper passed Debian 6.1 QEMU in `qemu-offline-20261115-155720`.

It also passed a separate full-system **Linux 3.10.108 VExpress** test in
`artifacts/docker-runtime/qemu-legacy-20261115-160528/`. This generic simulation
is built from the kernel.org archive with SHA256
`3849ea8119517f605f9d53c57dd6c539af8d584c2f1d9031f4f56283af3409a5`,
using the already pinned GCC 4.9 compiler, a separate build directory and
VExpress defconfig plus the container feature fragment. The small QEMU-only
fragment enables the legacy proc device-tree interface and a QEMU release tag.
Archive checksums are checked against kernel.org's HTTPS checksum listing;
publisher GPG signature verification is not claimed. Exported kernel, config
and DTB hashes are in `artifacts/docker-runtime/2026-11-15/qemu310-kernel.json`.
This kernel/DTB must never be used as a MiBox board candidate.

For the corrected candidate, build to separate output directories:

```sh
bash scripts/build-docker-sandbox.sh
python3 scripts/build-docker-experiment.py --rootfs-output target/mibox-rootfs-docker2
bash scripts/build-docker-qemu-legacy.sh
python3 scripts/test-docker-experiment-qemu.py --legacy --rootfs target/mibox-rootfs-docker2
python3 scripts/build-meson6-boot-test.py --rootfs target/mibox-rootfs-docker2 --output target/mibox-boot-candidate-docker2
```

The legacy QEMU build expects `target/docker-qemu-download/linux-3.10.108.tar.xz`
from `https://cdn.kernel.org/pub/linux/kernel/v3.x/`; it verifies the fixed hash
before extraction. The default for `Test-MiboxDocker.ps1` and the Docker image
guard tests is now DockerKernel2. The first candidate remains separately pinned.

## Second physical trial: offline container PASS

Evidence: `artifacts/docker-runtime/physical-20261115-160624/`.
The complete 8 MiB DockerKernel2 candidate was uploaded and read back with its
exact pinned SHA256 before boot. New custom boot ID:
`1924e1cc-3d29-4b48-847c-9ef180f57cb4`. Actual `/init`, `/bin/mibox` and the
decompressed running embedded config matched the candidate/build. The 66739596
byte external payload was also fully pulled back and hash-matched before the
root bootstrap independently copied and checked it.

The actual box reported Docker 24.0.9, ARMv7, kernel 3.10.99, VFS storage,
cgroupfs/cgroup v1, and the builtin seccomp profile. The local imported image
ID was `sha256:2a46da3afc0d84305a82fabe018702ab9241796284ce937f7775eb6195af01b1`;
this import ID includes runtime metadata, while the fixed input tar hash above
is the reproducible content pin.

`experiment.log` records daemon readiness, image import, container run,
`CONTAINER_EXEC_PASS`, `DEFAULT_SECCOMP_PASS`, logs, stop/remove, and
`MIBOX_DOCKER_OFFLINE_TEST_PASS` with experiment exit 0. Inspect reported a
33554432 byte memory limit and 500000000 NanoCPUs. This establishes configured
limits, not enforcement under load. Parent mount tables matched exactly before
and after the test, and the final process inventory had no Docker/runtime/
sandbox process left. No block filesystem or physical Ethernet interface was
used. Normal software return independently passed in
`artifacts/software-return/return-20261115-162915/`: original stock fingerprint,
boot_completed=1 and fresh Android boot ID
`780c872e-b8a2-48dc-bbcb-3b23582a85db`. The overall round-trip result is PASS;
the box is back on stock Android. Neither physical trial flashed firmware or
used a persistent container-data directory.

Remaining acceptance: registry pull and CA/clock setup, physical Ethernet and
bridge/NAT/published ports under this kernel, workload resource enforcement,
persistent volumes and engine restart/reboot, PID1 service supervision and
authenticated remote management. This offline PASS does not close those gates.

## Persistent Docker on the Slim system, 2026-11-19 (RAM boot)

Kernel: the pinned 3.10.99 container kernel with board patches
`kernel/patches/0000-mibox-casablanca-emmc-ethernet.patch` (stock MPT table
offset 2 MiB; stock Ethernet clock/mode registers, pinctrl and PHY reset) and
`0002-bridge-local-fdb-for-newlink-address.patch` (a bridge created with an
address gets its local fdb entry; without it docker0 never passed unicast
frames up to the host). Userspace: the Slim image built with
`build-slim-rootfs.py --kernel-dev`, RAM-booted as `SlimKernelDev6`
(`ac5526de…`). Not written to flash; HDMI is not shown on this kernel yet
(`mibox-fbhandoff` rejects its fb0 layout).

Engine: Alpine `docker-engine`/`docker-cli` 28.3.3 (containerd 2.1.5,
runc 1.3.7) and `iptables-legacy` in the persistent tree on data, enabled by
the owner opt-in file `/etc/mibox-docker.enabled` in the tree.
`/sbin/mibox-docker supervise` (started by `mibox-slim-start`) mounts a tmpfs
`/run` and the cgroup v1 hierarchies in the tree, points
`/usr/local/sbin/iptables*` at `xtables-legacy-multi`, writes a default
`/etc/docker/daemon.json` (vfs, no ip6tables, local logs 3×10 MB) if absent
and restarts dockerd with back-off. The persistence stop first runs
`mibox-docker stop` (TERM, up to 30 s), then unmounts everything below the
tree deepest first.

| Check (physical) | Result |
| --- | --- |
| hello-world (arm32v7), alpine:3.22 with 64 MiB memory limit | PASS |
| Container → bridge gateway, Internet, DNS | PASS (with patch 0002) |
| `nginx:alpine -p 8080:80`, fetched from the PC | PASS |
| Stop-Mibox with a running container | PASS: dockerd stopped, data unmounted |
| Next RAM boot: dockerd auto-start, `--restart unless-stopped` container back, PC fetch without manual steps | PASS (`artifacts/rescue-boot/20261119-205425-905`) |
| `--pids-limit` | Not supported (no pids controller) |
| overlay2 | Not supported; vfs copies every layer |

Day to day: `ssh root@192.168.1.222`, then `docker …` inside Alpine. Disable
the engine with `rm /etc/mibox-docker.enabled` (takes effect at the next boot).
Remaining: HDMI on 3.10.99, writing this kernel to boot1 (owner approval),
remote Docker API with TLS.
