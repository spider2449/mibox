# Meson6 kernel atomic-context follow-up, 2026-11-21

Status: offline fixes built successfully for the pinned 3.10.99 vendor kernel.
Dev11 passed targeted hardware validation from RAM. Automatic default-route
recovery after Ethernet down/up remains open. Dev10 remains installed.

The [runtime log](../artifacts/health/20261121/dmesg.txt) contains four
diagnostics from three vendor paths. They are retained as the baseline.

| Diagnostic | Source path and cause | Change |
| --- | --- | --- |
| Sleeping in `register_irq_proc`, CPU1 idle thread | `arch/arm/mach-meson6/time.c`: local timer setup calls `setup_irq`, reaching a procfs mutex with IRQs disabled | Register the local timer IRQ actions in `meson_timer_init`; a stable clock cookie dispatches to the per-CPU event once available |
| `smp_call_function_many` and `smp_call_function_single` warnings | `arch/arm/mach-meson6/clock.c`: `meson_clk_set_rate` disables local IRQs before A9's synchronous cross-CPU call | Enable the existing `open_irq` option for A9 only; retain `clock_ops_lock` and `clockfw_lock` serialization |
| Sleeping allocation in Ethernet open | `drivers/amlogic/ethernet/am_net8218.c`: both callers of `alloc_ringdesc` hold `np->lock` with IRQs disabled | Use `GFP_ATOMIC` for descriptor allocations; check allocation results before address conversion and clean up RX descriptors if TX allocation fails |

The timer registration uses B for CPU0 and D for CPU1, as the original
`2 * cpu + 1` mapping does. It rejects unavailable timers or failed IRQ setup,
allowing the ARM timer caller's existing broadcast fallback. CPU1 affinity
is set before enabling its timer. The handler tolerates a missing event before
CPU setup; CPU re-entry reuses the registered action rather than registering
the same action again. These are source-level properties, not hotplug proof.

The clock change retains the vendor SMP transition mechanism and its current
PLL programming. It does not establish freedom from interrupt-time lock
dependencies or safe transitions on hardware. Ethernet tests cover descriptor
allocation failure; existing RX-buffer partial allocation, DMA failure and
runtime reset recovery require separate coverage.

## Offline verification

Source commit: `8b1bb2b31a8e94b773a4b8ab907a0473a0951192`.
Compiler commit: `111258a10e017f067b27e6cfcea7619d753f3309` (Android GCC 4.9).

The complete patch set was applied independently to temporary copies of the
pinned files, preserving their modes. All nine resulting files matched the
working source byte for byte. The build preparer separately checks the source
revision and exact concatenated patch diff. Evidence:
[patch verification](../artifacts/kernel-atomic-context/20261121/patch-verification.json).

`scripts/test-kernel-ringalloc.py` extracts the actual allocator into a host
fault-injection harness. RX failure, TX failure cleanup and success pass for
both coherent and noncoherent branches, under AddressSanitizer and UBSan.
This verifies allocation control flow with mocked DMA, not actual DMA or
Ethernet behavior. [Test output](../artifacts/kernel-atomic-context/20261121/ringalloc-tests.txt).

Reproduce under WSL Ubuntu-24.04:

```sh
bash scripts/prepare-mibox-kernel.sh
python3 scripts/test-kernel-ringalloc.py \
  --source /home/morefunfun/.cache/mibox-kernel/vendor-source
MIBOX_KERNEL_EVIDENCE=2026-11-21-atomic-context \
  bash scripts/build-mibox-kernel.sh containers-v1
```

The build records source, compiler, configuration, patches, output hashes and
warnings in [the build record](../artifacts/kernel-meson6/2026-11-21-atomic-context/containers-v1/build.json).
The configuration remains the cgroup-v1/VFS profile; no pids controller or
overlayfs is added. The build does not package a boot image or deploy anything.

Final zImage: 4,119,056 bytes, SHA256
`8c9af782423ba21c5e6952d47887503cb3f4d906b298b182fe8c449b8a15ca63`.
Resolved configuration SHA256:
`ace17f68a0d1d0c9084dae437d8456b6719fcb720b43b92f6295951c4c67ab5c`.
An independent post-build check matched all four outputs, exported copies,
patches, configuration and build-log hashes:
[verification summary](../artifacts/kernel-atomic-context/20261121/build-verification.json).
ARM32 ELF, ARM zImage magic and exact LZMA expansion to Image passed the build
recorder's checks. Ten vendor build warnings remain recorded; no warning names
the three modified source files. The fixed build timestamp is reproducible
metadata and does not represent the actual build date.

## Dev11 RAM validation

On 2026-11-21 the C003 loader matched CRC32 `a6a2214f` over all 8 MiB of
the pinned Dev11 image. The control transfer returned without completion
status, then the observer verified the new runtime and both executable hashes
over ADB. Boot ID `b1f3fd5b-7d51-44de-9c8c-794178d15ce6` also matched over
SSH. [Loader record](../artifacts/rescue-boot/20261121-160059-738/result.json)

- Both CPUs were online. In three seconds, CPU0 timer B advanced from 5357
  to 6016 and CPU1 timer D from 4647 to 6020. Uptime advanced from 15.59 to
  18.59 seconds. [Counter samples](../artifacts/kernel-atomic-context/20261121/dev11-ram/baseline.txt)
- Three cycles between performance and conservative reached 1368000 kHz
  and returned to 192000–264000 kHz. The original conservative governor
  was restored. [Frequency samples](../artifacts/kernel-atomic-context/20261121/dev11-ram/cpufreq.txt)
- Administrative Ethernet down/up restored carrier at 100 Mbps full duplex,
  the static address, gateway ping and SSH. It removed the IPv4 default route,
  which was restored manually through SSH. Docker exec, container-to-gateway
  ping and published HTTP 200 passed. [Link test](../artifacts/kernel-atomic-context/20261121/dev11-ram/link-and-container.txt)
  [Route recovery](../artifacts/kernel-atomic-context/20261121/dev11-ram/post-link-route.txt)
- The final kernel log contains none of the four baseline atomic-context
  diagnostics. The existing ext4 discard and cgroup hierarchy messages remain.
  [Final kernel log](../artifacts/kernel-atomic-context/20261121/dev11-ram/dmesg-final.txt)

This run used the already-present C003 loader and left Dev11 running in RAM
with the original route and governor. It issued no flash command. Cold entry,
long-duration stability and automatic route recovery remain separate gates.
