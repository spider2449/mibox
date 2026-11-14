# Stage-one external-load interface

1. [x] Audit the exact external-reader call and command helper.
2. [x] Compare register/command structure with pinned Meson6 SDIO source.
3. [x] Record byte/block addressing and bounds without creating boot media.
4. [x] Keep physical port, boot-ROM selection and restoration readiness explicit.

The exact binary is consistent with SD/MMC CMD18/CMD12 and starts media reads
at byte 32768. Owner confirmed no SD slot. Direct external-card testing is
therefore unavailable within the no-disassembly constraint; cold-boot
selection remains UNKNOWN. No media produced.
