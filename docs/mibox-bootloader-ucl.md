# Exact stock bootloader recovered from UCL

The pinned named bootloader backup contains a complete UCL stream beginning
at file offset 32768, ending at 355452. The NRV2D method (0x2d), level 7,
262144-byte block limit and all three output lengths validate. Safe decoding
produces 736816 bytes; Adler32 matches `262f06af`. Expanded SHA256:

`99f701ac15a155aa07b7204d240b82a0a5c91457513ae1e246146e3f8b8753a2`

The expanded bytes contain the banner
`U-boot-00000-g5ff8b7c(m6_casablanca@5ff8b7c0) (2015-08-12 - 17:20:46)`.
Earlier negative string scans were against compressed input and do not apply
to this expanded payload. This is actual backed-up device content, separate
from the public codesnake source used in earlier protocol work.

The parser follows the [UCL uclpack format implementation](https://github.com/rockbox/rockbox/blob/master/tools/ucl/uclpack.c).
It uses Ubuntu noble libucl1 1.03+repack-6, downloaded and unpacked locally
without system installation. The package SHA256 matches the apt metadata:
`2117fbffff0638da71bf6a741dd05e7f54f405d3070a1e5b940135260f642390`.
The extracted shared library hash is separately pinned before loading it.
Only the host decompression library runs; no firmware code runs.

## Command addresses derived from the image

The `irdetect` name and usage string offsets, their pointer difference in a
valid command-table entry and its argument/repeat/function fields identify
one link base: `0x8f800000`. The vector-area self-address literal at file
offset 0x40 independently matches it. The monitor_bt_cmdline and saveenv
registrations also resolve consistently under this base. This identifies
static link addresses; actual runtime relocation remains unobserved.

| Registration | Handler link address | Expanded file offset |
| --- | --- | --- |
| irdetect | 0x8f8706f0 | 0x706f0 |
| monitor_bt_cmdline | 0x8f80dc58 | 0xdc58 |
| saveenv | 0x8f815490 | 0x15490 |

The IR decoder compares its internally assembled value to `0x002180f4`
(literal at expanded offset 0x706bc). Equality returns 1 from the decoder;
the registered irdetect handler returns command success 0 on detection and
1 after its bounded loop expires. That matches the saved environment's
`if irdetect; then run recovery; fi` use. The loop count is 1000000;
elapsed time is UNKNOWN, so this is not a measured one-second window.
Physical button identity, protocol interpretation and cold-start operation
remain UNKNOWN. This value is not a Linux input keycode.

The BT helper's accepted-response branch calls link address `0x8f81cc58`
from `0x8f80dbdc`. The registered saveenv handler calls the same backend
from `0x8f8154b4`. Thus a successful BT detection path includes environment
save behavior; it must not be represented as a read-only key probe. The actual
saved bytes, storage outcome and physical response behavior remain untested.
Saved preboot/storeargs independently already contain saveenv operations.

The expanded built-in default storeboot reads `boot`, whereas the saved
CRC-verified environment reads `boot1`. Built-in defaults must not replace
the current saved environment or establish the active boot selection.
No defenv, saveenv, IR/BT command, flash command or boot command was issued.

## Reproduction and evidence

From `phone-tools/source-reference` under WSL, obtain the pinned package using
`apt-get download libucl1=1.03+repack-6`, verify its hash and unpack it with
`dpkg-deb -x libucl1_1.03+repack-6_amd64.deb ucl-runtime`.
Then run these scripts from the repo under WSL Python3:

```sh
python3 scripts/extract-bootloader-ucl.py
python3 scripts/inspect-loader-commands.py
```

The second script requires arm-linux-gnueabihf-objdump, derives the base,
checks audited instruction words/call targets, and retains bounded
disassemblies. Extracted firmware remains under ignored phone-tools.

- [Container, block checks and decoder provenance](../artifacts/restoration/2026-11-14/bootloader-ucl.json)
- [Derived registrations and audited paths](../artifacts/restoration/2026-11-14/loader-command-addresses.json)
- [IR handler and helpers](../artifacts/restoration/2026-11-14/loader-irdetect-disassembly.txt)
- [BT handler and helpers](../artifacts/restoration/2026-11-14/loader-monitor_bt_cmdline-disassembly.txt)
- [saveenv handler](../artifacts/restoration/2026-11-14/loader-saveenv-disassembly.txt)

Independent USB loader entry and physical restoration remain unverified;
permanent installation remains **NOT READY**.
