# MiBox container runtime, 2026-11-15

Goal: run Docker containers on the MiBox itself, following pi2-os's device-side
design. This is not a host Docker build request.

1. [x] Inspect pi2-os's Docker and Rust-native engines and kernel fragment.
2. [x] Audit the recovered MiBox kernel configuration with a repeatable tool.
3. [x] Record blockers and an implementation/physical acceptance sequence.
4. [x] Identify and pin a hardware-relevant Meson6 BSP; establish a legacy
   cgroup-v1/VFS route. Modern overlayfs/cgroup-v2 support remains a separate
   kernel-port milestone.
5. [x] Build the development kernel and prove physical RAM boot, six container
   primitive diagnostics and software return to Android. Full peripheral
   validation remains outstanding; the default boot path was not changed.
6. [x] Integrate one engine with PID1 supervision, dedicated persistent storage,
   networking, clock/CA setup and authenticated remote control. Done 2026-11-19:
   Alpine docker-engine 28.3.3 supervised by `mibox-docker`, data-backed tree,
   bridge/NAT, mTLS API on 2376 (see ../mibox-docker-runtime.md).
7. [x] Prove image pull, run/exec/stop, published ports, resource limits,
   persistent volumes and restart on the physical box. Done 2026-11-19 after
   the docker exec mount-namespace fix (SlimKernelDev9 on boot1).

## Engine payload preparation

- [x] Select Docker 24.0.9 ARM static binaries as a legacy development candidate,
  pin the official HTTPS archive and inventory all eight ARM ELF32 executables.
- [x] Probe CLI/daemon/containerd/runc/ctr/tini versions with host QEMU and
  validate the VFS/cgroupfs RAM-only daemon configuration without starting it.
- [x] Check ELF rejection cases for wrong architecture, dynamic dependencies
  and out-of-bounds headers/segments (four host tests).
- [x] Stage a separate Alpine + engine RAM payload onto the dedicated DockerKernel2,
  establish private mounts/cgroup-v1 mounts and prove local Unix socket readiness.
  The existing small kernel-test image does not include Alpine or these binaries.
- [x] Run a pinned local ARMv7 image first, preserving default seccomp and normal
  restart cleanup. Add network/persistent storage only after this engine gate.

Prepared payload: `/home/morefunfun/.cache/mibox-docker-24.0.9-ram-test` (WSL).
Evidence: `artifacts/docker-runtime/2026-11-15/docker-payload.json`.
This is a historical compatibility experiment, not a production engine choice.

## Offline physical engine gate

Use a new DockerKernel RAM candidate with unchanged ContainerKernel2 init,
userland, kernel and DTB. Add BusyBox/musl, a fixed root bootstrap and a bounded
namespace supervisor. PID1's existing console-start hook launches only the
immutable bootstrap. It accepts a separately uploaded archive only after copying
it into root-owned RAM and matching its build-time SHA256.

1. [x] Build the payload, RAM rootfs and independently inspected 8 MiB candidate.
2. [x] Prove offline daemon/import/run/exec/default-seccomp/stop/remove in generic
   full-system ARM QEMU; this is not target-kernel compatibility proof.
3. [x] Check candidate rejection guards, unchanged kernel/DTB/init and restart pins.
4. [x] Full upload/readback, physical boot and actual config/userspace hash checks.
5. [x] Upload and verify the pinned RAM payload, observe local engine and offline
   container results. No physical network interfaces or block devices are used.
6. [x] Prove sandbox process/mount cleanup, then independently verify normal
   return to completed stock Android with a fresh boot ID.

The supervisor bounds the namespace leader to 240 seconds and kills it on
timeout, destroying all descendant processes. Failed trials remain recorded.
Bridge/NAT, registry pull, persistent storage and service integration are later
gates; a successful offline trial does not close the full Docker acceptance.

Candidate SHA256: `3d0be1a75f59e1ecd21459768b603cef8c3c769e0e31f69445d68cf34bf3f2dc`.
Payload SHA256: `33bba141e73e1a296f1c3bb425c8df2cd20593656275ecdfaa417dcc9824b880`.
Passing full-system QEMU evidence: `artifacts/docker-runtime/qemu-offline-20261115-134609/`.
Failed 6.12-v1 and
root-transition trials remain alongside it. Root transition uses a private
tmpfs mounted onto the namespace root followed by chroot, preserving the
original shared RAM rootfs instead of deleting it with switch_root.

First physical trial: `artifacts/docker-runtime/physical-20261115-134811/`.
Full image and payload readback, actual kernel config/init hashes, sandbox
cleanup and Android return passed. Engine test failed before daemon startup:
Linux 3.10.99 rejected a redundant recursive bind of the original rootfs with
EINVAL. Return evidence: `artifacts/software-return/return-20261115-141047/`;
completed Android boot ID `5a485ea0-78e5-4249-8ff0-c3d13c886b72`.

The corrected supervisor removes that bind and preserves the private tmpfs
root transition. Modern QEMU passed again in
`artifacts/docker-runtime/qemu-offline-20261115-155720/`. A separate upstream
Linux 3.10.108 VExpress fixture passed the full offline workload in
`artifacts/docker-runtime/qemu-legacy-20261115-160528/`;
it is QEMU-only and must never be used as a MiBox kernel or DTB.

Second candidate `DockerKernel2` SHA256:
`13794e4423287cc12ea2b63bff22a937b156d70d54fb4141ba9342ea4b19c1fa`.
It retains the identical kernel, DTB, PID1, userland and external payload. Only
the RAM sandbox executable differs. Old candidate pins and trial evidence are
preserved. Second physical trial `artifacts/docker-runtime/physical-20261115-160624/`
passed daemon/import/run/exec/logs/default-seccomp/stop/remove and parent mount/
process cleanup. Independent normal Android return also passed:
`artifacts/software-return/return-20261115-162915/`, boot_completed=1 and new boot
ID `780c872e-b8a2-48dc-bbcb-3b23582a85db`. The box is back on stock Android.

Current result: replacement kernel RAM/primitive tests and physical offline
Docker workload PASS; full persistent engine integration is NOT READY.
Stock CONFIG_NAMESPACES=n remains a blocker under the original kernel.
The tested replacement supplies namespaces and the legacy profile, but lacks
cgroup v2 and overlayfs. Existing chroot/SSH success alone does not establish
container isolation; the new primitive tests are separately recorded.

Details: ../mibox-docker-runtime.md. No device operations are needed for this
initial source/configuration audit.
