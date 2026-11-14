# Cold recovery-entry preflight

The owner has no SD slot, has a working Mi Box infrared remote, and excluded
TV/home-screen work. Individually confirmed BACK/UP/DOWN events are retained
in the [remote-input record](mibox-remote-input.md). The next candidate is
an owner-operated HOME+MENU cold start, sourced separately from
[Xiaomi's general IR recovery guidance](https://www.mi.com/service/box/update).
Actual entry on this exact device remains untested.

## Current pending-state observations

The established temporary-root diagnostic ran with UID0, GID1000 and
init_shell context. It listed /cache but reported /cache/recovery absent;
command, extendedcommand and openrecoveryscript were absent there. No named
/dev/block/misc node appeared in the block-device listing. This does not rule
out every vendor boot-message mechanism or alternate alias.

An ordinary shell attempt had previously returned permission denied for the
cache paths; those results were not treated as absence. The privileged
[pending-state transcript](../artifacts/recovery-preflight/2026-11-14/pending.txt)
supplies the stronger observations above.

The diagnostic then read only the first 32768 bytes of /dev/block/env into a
new scratch file. Device-side and host SHA256 matched:
`f4ef0fc6526607b1977bcb02cd257a29ab9f69a8f3210777ab8f49fabeadcb89`.
The four-byte CRC matches the remaining 32764 bytes. Selected current keys:

| Key | Observation |
| --- | --- |
| wipe_data | Absent |
| recovery_command | Absent |
| boot-recovery | Absent |
| upgrade_step | 0 |
| storeboot | Reads boot1, then bootm, then recovery if execution returns |

[Device read/hash transcript](../artifacts/recovery-preflight/2026-11-14/env-read.txt)
and [CRC/key validation](../artifacts/recovery-preflight/2026-11-14/env-check.json)
are retained. The full current prefix stays under ignored phone-tools. This
is not a fresh full env-partition backup and no environment value was written.
Absence of these keys is not proof that all automatic recovery sources are
inactive. The exact recovery executable contains cache command, wipe_data,
recovery_command and /misc-related strings; its full startup control flow has
not been established from strings alone.

## Observer prepared and baseline verified

`scripts/Observe-MiboxColdRecovery.ps1` only queries USB PnP state and ADB.
It issues no reboot, loader request, key input, install or storage command.
`-BaselineOnly` passed and retained the original fingerprint, boot_completed=1
and a valid boot ID in
[baseline.json](../artifacts/recovery-entry/20261114-141746/baseline.json).
The full observer has not yet been run across a cold-start transition.

Before owner action, start the observer and wait for its STARTED notice.
The owner then disconnects box power, holds HOME+MENU aimed at its receiver,
reconnects power, and releases when recovery appears. Stop at that screen;
do not select update, wipe, reset or another system. Supply no update media.
Observe what is displayed and retain USB/ADB changes independently.

A visible menu establishes only recovery entry. A recovery ADB label, USB
enumeration or menu does not establish an interactive shell, normal Android
return or partition restoration. Normal bootloader/recovery startup may make
its own persistent writes. Host observation cannot guarantee their absence.
Permanent installation remains **NOT READY**.

## Validation and side effects of this preflight

The ARMv7 diagnostic release build and targeted rustfmt check passed. Its
deployed executable SHA256 matched the host build:
`b6df7f4f08ba7effcd03b9da99934671ae65fe068641cee2bad995b50050539a`.
Replacing the scratch executable reset its execute mode; one attempt was
denied before the diagnostic ran. Mode was restored and the successful run
produced the retained read/hash evidence. No root daemon was installed.

Only the diagnostic executable, env readback and result files were written to
/data/local/tmp. No raw partition write, environment update, reboot, recovery
entry or UI selection occurred in this preflight.
