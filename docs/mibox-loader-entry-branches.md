# Exact USB-loader entry branches

Offline audit of expanded bootloader SHA256
`99f701ac15a155aa07b7204d240b82a0a5c91457513ae1e246146e3f8b8753a2`
confirms the reason mapping below. Handler addresses are resolved through the
validated command table and derived link base, not borrowed from another box.

| Reason value | get_rebootmode result |
| --- | --- |
| 0x01010101 | normal |
| 0x02020202 | factory_reset |
| 0x03030303 | update |
| 0x09090909 | usb_burning |
| Unmatched value, with startup override inactive | charging |

The kernel's previously audited usb_burner_reboot branch chooses 0x09090909.
This now closes the static kernel-to-loader reason mapping using the actual
backups, in addition to the already successful physical Android-to-C003 test.
It still depends on a running system able to issue that restart.

## Separate startup override

Before its reason comparisons, get_rebootmode calls helpers at link addresses
0x8f851728 and 0x8f85170c. Both read the same word at 0xd901ff04. One returns
true for value 1, the other for an unsigned value greater than 1; either true
result selects `update` instead of the ordinary reason mapping.

The current word, who initializes it, and how an owner could influence it on
cold start are **UNKNOWN**. This is a static read address, not an instruction
to write a register. No read or write to this physical address was attempted.
It does not establish a button sequence, a boot ROM USB entry, or a recovery
procedure after an Android boot failure.

The saved environment's `update` runs `usb_burning`, then recovery if control
returns. Its `usb_burning` variable expands to `update 1000`; here `update`
is the registered USB command, distinct from the environment variable named
update and from the registered `sdc_burn` command. The saved key-detection
path instead invokes recovery directly. These entries must not be conflated.

## USB wait and timeout

The registered update handler at link address 0x8f85bcc8 parses its optional
argument, then calls the USB routine at 0x8f85bc00. Its timeout initializer
at 0x8f85b004 stores a nonzero argument directly as the threshold; argument
zero selects 5000000. The poll at 0x8f85bb98 compares the unsigned timer result
strictly greater than the threshold, but skips the timeout check when its
timeout-state word is zero. The timer units and cancellation paths are not
established by this bounded audit; do not interpret `update 1000` as a measured
one-second automatic return. Earlier physical evidence already showed a
loader session can remain present and require owner power recovery.

The USB command and sdc_burn have distinct registrations and handlers. This
does not prove all USB callees or possible host requests avoid persistent
writes. No SD burning file, update package, boot image or media was prepared.
Existing RAM-only host tools remain limited to their fixed verified path.

## Reproduction

After the [UCL extraction](mibox-bootloader-ucl.md), run under WSL Python3:

```sh
python3 scripts/inspect-loader-commands.py
python3 scripts/inspect-loader-entry.py
```

The command-table resolver accounts for C string suffix pooling: a command
name pointer can point inside a longer string. It still requires a unique
registration with valid argument/repeat fields and a function inside the
expanded payload. The branch audit pins input hashes, checks selected actual
instruction words, resolves mode strings and retains disassemblies.

- [Branch audit and remaining UNKNOWN values](../artifacts/restoration/2026-11-14/loader-entry-branches.json)
- [Reboot-mode handler](../artifacts/restoration/2026-11-14/loader-get_rebootmode-disassembly.txt)
- [Startup status helpers](../artifacts/restoration/2026-11-14/loader-startup-state-helpers-disassembly.txt)
- [USB wait helpers](../artifacts/restoration/2026-11-14/loader-usb-wait-helpers-disassembly.txt)
- [Timeout initialization](../artifacts/restoration/2026-11-14/loader-usb-timeout-init-disassembly.txt)

No device operations were performed. An independently usable loader entry
and physical restoration remain unverified. Permanent installation is
**NOT READY**. Physical IR button identity also remains UNKNOWN.
