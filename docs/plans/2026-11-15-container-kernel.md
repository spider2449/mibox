# MiBox container-capable kernel

Goal: build a hardware-relevant casablanca/Meson6 kernel with container support.

1. [x] Locate and pin a Meson6-capable source tree; compare its DT binding,
   drivers, memory handling and stock configuration with recovered evidence.
2. [x] Select the feasible kernel route and record unsupported assumptions.
   First BSP milestone: cgroup v1/VFS; modern pi2-os engine remains unsupported.
3. [x] Prepare reproducible source/toolchain/configuration on WSL Linux storage.
4. [x] Build baseline and container-enabled kernel, inspect artifacts and audit
   resolved configuration. Keep unrelated source trees and evidence intact.
5. [x] Establish an evidence-based RAM experiment: unchanged stock DTB, matched
   memory model, checked load bounds, exact development guard, independent
   image inspection, existing return regression checks and owner power recovery.
6. [x] Validate temporary board boot with actual userspace and config hashes.
7. [x] Validate container primitives and software return with ContainerKernel2.
   All six diagnostics passed; actual embedded config and userspace hashes
   matched. Android returned with boot_completed=1 and a fresh boot ID.

Only actual device evidence can establish board compatibility. A compile,
reference board DTB or generic QEMU test cannot establish that. Do not use Pi2
or S905 device trees for this Meson6 device, and do not guess hardware values.
No persistent flash, boot environment changes or default boot installation is
part of kernel development here. First physical boot passed; the initial guard
expected the BSP's full banner tag rather than its short uname release. Owner
power recovery passed. The corrected userspace retains the same kernel bytes.
Second trial: artifacts/kernel-meson6/physical-20261115-122806/.
Result: PASS for this temporary legacy container-kernel development milestone.
Docker engine and complete new-kernel peripheral validation remain separate.
