# Vendor kernel atomic-context fixes, 2026-11-21

Scope: source patches, kernel build and RAM validation. Preserve the installed
Dev10 image and the physical warning log in `artifacts/health/20261121/`.

1. [x] Trace all startup atomic-context diagnostics to the pinned vendor source.
2. [x] Register the two local timer IRQs during early timer initialization,
   before secondary CPU startup; retain per-CPU event dispatch.
3. [x] Keep IRQs enabled during the A9 clock's synchronous SMP callback, using
   the vendor framework's existing `open_irq` path and serialization.
4. [x] Use non-sleeping allocations for Ethernet rings under the existing
   spinlock, with allocation failure checks before address conversion/use.
5. [x] Verify the patch set against the pinned source and build containers-v1.
6. [x] Record artifact hashes, configuration provenance and physical limits.
7. [x] Package and pin SlimKernelDev11 for RAM testing. Reuse the Dev10
   ramdisk and DTB, and verify their section hashes against Dev10.

SlimKernelDev11 is at
`target/mibox-boot-candidate-slim-kernel-dev11/boot1-custom.NOT_READY.img`.
The image is 8,388,608 bytes with 6,336,512 bytes used including alignment.
SHA256 is `d84d6ebf0018101e5ef8b713a1df390d595aa298ffefa3e5025cbf6893e395b3`.
The rescue launcher local check passed. See
`artifacts/rescue-boot/20261121-082651-235/local-check.json` and the manifest
and independent inspection under `artifacts/kernel-atomic-context/20261121/`.

Result: offline build PASS; targeted RAM kernel validation PASS. ARM32 ELF, zImage
magic, LZMA payload, four output sizes/hashes, exported copies and the resolved
configuration were verified. Six allocator fault-injection cases passed under
ASan/UBSan. The final build retains ten vendor build warnings in its record.
Details: [source analysis and acceptance](../mibox-kernel-atomic-context.md).

8. [x] RAM-boot Dev11 and verify the CPU timer, frequency, Ethernet and Docker
   behavior. The final log has none of the four baseline diagnostics.
9. [ ] Resolve and retest default-route recovery after administrative Ethernet
   down/up before considering installation. The test restored the route manually.
