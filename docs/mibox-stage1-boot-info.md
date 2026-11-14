# Stage-one startup state traced to boot information

The exact named bootloader backup's first 32768 bytes have SHA256
`3c0f1eba7a1aa6eaaaefb7c4cf5b5d86cae7f8d3cb8490a571856850542370c8`.
The startup relocation destination at file offset 0x98 is 0xd9000000;
exception-vector targets independently corroborate this static link base.
It is not a newly assumed device execution address.

The stage-one load-dispatch routine at file offset 0x2a68 follows this chain:

| Step | Exact backup evidence |
| --- | --- |
| Pointer slot literal at file 0x2b34 | 0xd90000b4 |
| Pointer stored at file 0xb4 | 0xd901ff00 |
| Second word loaded from that structure | Address 0xd901ff04 |
| Field equals 1 | Calls routine at file 0x2102; prints ext dev on success |
| Field equals 0 or unsigned value greater than 1 | Calls routine at file 0x2728; prints int dev on success |

The consumed word is exactly the same address read by the expanded loader's
[startup override](mibox-loader-entry-branches.md). The two consumers differ:
stage one treats only value 1 as external loading, whereas the later mode
selection treats any nonzero value as an update override. Thus a nonzero
value alone must not be classified as an external-device boot or USB entry.

## Public source cross-check

The pinned reference [Meson6 romboot.h](https://github.com/codesnake/uboot-amlogic/blob/c0b0b8cc9bd5901ced2e929ea87b99fae52d528c/arch/arm/include/asm/arch-m6/romboot.h)
places its boot-return information at SRAM-end minus 256, or 0xd901ff00,
and names the second field `boot_id`. Its
[loaduboot.c](https://github.com/codesnake/uboot-amlogic/blob/c0b0b8cc9bd5901ced2e929ea87b99fae52d528c/arch/arm/cpu/aml_meson/common/firmware/loaduboot.c)
uses that field to select internal/external loading with the same value-1
distinction. The reference
[romboot.c](https://github.com/codesnake/uboot-amlogic/blob/c0b0b8cc9bd5901ced2e929ea87b99fae52d528c/arch/arm/cpu/aml_meson/m6/firmware/romboot.c)
contains matching diagnostic labels.

The field name is a source-supported interpretation of the observed layout,
not proof that the reference is Xiaomi's exact source. Retained text was
checked against the pinned Git blob hashes, allowing only newline-format
normalization. No source constant was substituted for the backup's pointers.

## What remains unknown

The initial writer of this field, its runtime value, an owner-operated cold
start trigger, and the physical interface meant by external loading remain
UNKNOWN. The bounded routines inspected are consumers; this is not a
whole-program proof that stage one never modifies the field. The public
header is not a dump of this device's boot ROM.

The result narrows the earlier unnamed status word to an actual shared
boot-information field. It supplies no verified cold-start rescue sequence.
No physical address was read or written; no ARM code, media or device operation
was executed. Permanent installation remains **NOT READY**.

Reproduce under WSL Python3 after the prior loader audits:

```sh
python3 scripts/inspect-stage1-boot-info.py
```

- [Pointer chain, instruction checks and reference provenance](../artifacts/restoration/2026-11-14/stage1-boot-info.json)
- [Startup disassembly, shown as file offsets](../artifacts/restoration/2026-11-14/stage1-startup-disassembly.txt)
- [Load dispatcher](../artifacts/restoration/2026-11-14/stage1-load-dispatch-disassembly.txt)
- [Source diagnostics](../artifacts/restoration/2026-11-14/stage1-source-diagnostics-disassembly.txt)
- [External load routine](../artifacts/restoration/2026-11-14/stage1-external-load-disassembly.txt)

## External-reader interface narrowed down

The exact external-load routine at file 0x2102 calls the reader at 0x1bb4.
Its command helper at 0x1b64 writes an argument and command to controller
registers. The reader's literals include 0xc1108c60, 0xc1108c28, 0xc1108c34
and 0xc1108c38. Command bases are 0x00222d52 and 0x00082d4c; their low bytes
are 0x40+18 and 0x40+12 respectively. The register/command sequence matches
the pinned reference [Meson6 sdio_read implementation](https://github.com/codesnake/uboot-amlogic/blob/c0b0b8cc9bd5901ced2e929ea87b99fae52d528c/arch/arm/cpu/aml_meson/m6/firmware/sdio.c),
supporting the interpretation of SD/MMC CMD18 read and CMD12 stop.

The media byte offset starts at 32768, total reads round to 512-byte sectors,
and each chunk is at most 65536 bytes. For the card-type values 1 and 3, the
media offset is shifted right by 9 for the command argument; other values use
the byte offset directly. These bounds and comparisons are present in the
actual binary, not inferred from an Android boot-image header.

This narrows external loading to an SD/MMC-style reader, but does not establish
a USB mass-storage boot route or identify an accessible SD/microSD socket.
It also does not define the complete first-stage/card layout, Boot ROM
selection policy, validation policy or a usable physical rescue procedure.
No media image was assembled or written. The owner subsequently confirmed
that the box has no SD slot. This rules out a directly accessible card-slot
experiment within the no-disassembly constraint. It does not prove that the
SoC lacks SDIO or that internal board signals are accessible. Do not substitute
a USB card reader: no USB mass-storage boot path has been established.

The audit report now includes external-reader details and a fourth pinned Git
reference; [reader and command-helper disassembly](../artifacts/restoration/2026-11-14/stage1-external-reader-disassembly.txt)
is retained. The audit script passed after these additions.
