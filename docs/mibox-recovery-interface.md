# Stock recovery input and interface evidence

Offline inspection of the hash-pinned recovery image recovered a 462104-byte
ARM ELF32 executable with SHA256
`fc17c13f75a9f2909ca70a2a1339b3838e87ad165f326fa96cc50346e5d43b3e`.
It has no ELF symbol table. No firmware executable or script was run.

The same cpio archive contains `etc/recovery.kl` with these rows:

| Action label | Input codes |
| --- | --- |
| select | 28, 15, 158 |
| down | 108, 114, 109 |
| up | 103, 104, 115 |
| back_door | 128, 26, 118 |

The file comments identify select codes as ENTER/TAB/BACK, down codes as
DOWN/VOLUMEDOWN/PAGEDOWN, and up codes as UP/PAGEUP/VOLUMEUP. The
`back_door` behavior is UNKNOWN; its name does not establish a rescue feature
or permission bypass. No such input was sent.

The executable includes `/etc/recovery.kl`, loaded/fallback diagnostics and a
key-map-table diagnostic. This supports investigating that configuration but
does not prove the exact parser semantics or every action's reachability.
These are recovery-runtime input codes, not bootloader cold-start button
combinations; translating them into a startup key sequence is unjustified.

Other observed strings include `send down key`, `send up key`, `send ok key`,
`bluetooth`, `apply update from ADB`, `Reboot System`, system-one/system-two
choices, wipe confirmations, and a key-input timeout/reboot diagnostic.
The actual timeout duration and selection behavior remain UNKNOWN. String
presence alone does not establish working Bluetooth or a reachable menu.

The executable also contains minadbd/sideload implementation paths and
`sideload_service invoked`. ADB sideload is not evidence of an interactive
rescue shell. The extracted init still leaves the separate adbd service
disabled under stock properties. No USB rescue-shell claim is established.

Any future physical observation should first establish the displayed screen
and USB identity without selecting update, wipe, slot-switch or undocumented
menu actions. It requires owner power/remote participation and a separately
established cold-start entry sequence. Do not test by damaging Android.

Reproduce from the repo:

```powershell
wsl -d Ubuntu-24.04 -- python3 /mnt/f/coding/otherPrj/mibox/scripts/inspect-recovery-interface.py
```

The parser verifies the complete source image hash, section bounds and cpio
trailer; output paths are fixed. Extracted firmware remains privately under
`phone-tools/runtime/2026-11-14/recovery-interface/`. The report retains keymap
text, parsed rows, ELF sections, matching strings and file offsets:
[recovery-interface.json](../artifacts/restoration/2026-11-14/recovery-interface.json).

Independent loader entry and physical restoration remain untested.
Permanent installation remains **NOT READY**.
