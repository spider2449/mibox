# pids cgroup controller backport, 2026-11-25

Status: **SlimKernelDev13 `614861f6…` is installed in boot1 (2026-11-25)** after RAM
validation; a flash boot passed the same 27-check test (see the end of this file).

## What and why

The 3.10.99 vendor kernel has no pids controller (Linux 4.3+), so Docker's
`--pids-limit` did nothing and one container could fork-bomb the box.
`kernel/patches/0003-cgroup-pids-controller.patch` backports the 4.3
`kernel/cgroup_pids.c` to the 3.10 cgroup API:

- `pids.max` ("max" or 0–32768) and `pids.current` on every non-root cgroup.
  Limits are hierarchical; the root is never charged.
- 3.10 has no `can_fork`/`cancel_fork` subsystem callbacks. `copy_process()`
  calls `cgroup_pids_can_fork(p)` right after `cgroup_fork(p)`, charging the
  child's own css_set (fixed at that point, so a concurrent parent migration
  cannot split charge and membership), and fails the fork with `EAGAIN` at the
  limit. Every later error path falls through `cgroup_pids_cancel_fork(p)`.
- `can_attach`/`cancel_attach` move charges while `cgroup_attach_task()` holds
  the thread-group lock; `exit` uncharges the cgroup the task left. Migration
  ignores the limit (as upstream).
- The limit is an `atomic64_t`: 64-bit plain stores are not single-copy atomic
  on ARMv7.
- `pids` is appended last in `cgroup_subsys.h`, so other subsystem IDs keep
  their values.

`mibox-docker` now also mounts the `pids` hierarchy (skipped when
`/proc/cgroups` does not list it).

The patch check in `prepare-mibox-kernel.sh` and `record-mibox-kernel.py` now
compares tree hashes (`scripts/verify-kernel-patches.sh`: HEAD plus every patch
in a scratch index against the working tree, new and untracked files
included). The earlier byte comparison of `git diff` with the concatenated
patches required the patches to be in global path order, which a patch
touching `include/`, `init/` and `kernel/` cannot satisfy.

## Build

`MIBOX_KERNEL_EVIDENCE=2026-11-25-pids bash scripts/build-mibox-kernel.sh containers-v1`
([record](../artifacts/kernel-meson6/2026-11-25-pids/containers-v1/build.json)),
`CONFIG_CGROUP_PIDS=y`. The build had no compiler warnings in the changed
files. The 12 log warnings are the 10 known vendor ones plus two make
clock-skew notices. `fork.o` was rebuilt after the edit, and `copy_process`
in vmlinux calls both hooks.

Dev13 = this kernel + the Dev12 rootfs with the new `mibox-docker`. The stock
DTB is unchanged. It is pinned in `Test-MiboxLoaderRam.ps1` and
`rescue-boot.ps1`.

## RAM validation

Clean `Stop-Mibox`, owner power cycle with USB attached, C003 RAM boot
(`artifacts/rescue-boot/20261125-204710-454/`, image verified), boot
`4e953967-86b6-40ea-a8e6-34628f39e60b`.

`scripts/device/pids-test.sh`: **27/27 PASS**
([output](../artifacts/kernel-meson6/2026-11-25-pids/dev13-ram/pids-test.txt)):

- Interface: present and mounted, no files on root, invalid values rejected.
- Fork limit: with `pids.max=3`, counts read 1, 2, 3, then the next fork got
  `EAGAIN`. Exits uncharge.
- Hierarchy: a parent limit of 2 binds an unlimited child, and the parent
  counts the child's tasks.
- Migration: charges move in, across and out, ignoring the limit.
- Docker: no unsupported warning; `--pids-limit 8` refused forks, and a fork
  bomb under `--pids-limit 32` stayed at ≤ 32 tasks while the box kept
  responding.
- No accounting warnings in the kernel log.

The first run reported 5 failures, all test bugs: a wrong mountinfo pattern,
and expectations that ignored busybox ash exiting on a failed fork. That run
is kept in `pids-test-run1-test-bugs.txt`. A manual trace showed the kernel
counting correctly.

Regression ([output](../artifacts/kernel-meson6/2026-11-25-pids/dev13-ram/regression.txt)):

- `docker info` printed no warnings, and the container runs in
  `pids:/docker/<id>`.
- `docker exec`, the default route and netwatch, and HTTP 200 all work.
- The kernel log has no atomic-context, BUG or WARNING lines, and integrity
  reads MATCH.

Not covered: long-duration behavior, a flash boot of Dev13, and contention
stress between fork and migration.

## Installation, 2026-11-25

The owner approved the boot1 write
(`artifacts/console-root/20261125-205240-c10-dev13-boot1-write/`): current
content verified as Dev12 `772c2210…`, dry run, write, readback and an
independent re-hash `614861f6…`; boot `ff4fa440…` unchanged. With USB
unplugged, `Stop-Mibox -Restart` came back from flash in 21 s (boot
`f76bc3dc-8c4f-4e42-84ec-dc87c5321558`). `mibox-docker` matched Dev13
(`96322e9f…`), the pids hierarchy was mounted, and `mibox-web`, the route,
netwatch and HTTP 200 came up. There were no kernel warnings, integrity read
MATCH, and `pids-test.sh` passed 27/27. For a restore, the expected current
content is now `614861f6…`.
