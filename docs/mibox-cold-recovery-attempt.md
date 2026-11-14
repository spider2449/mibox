# Owner-operated cold recovery attempt

The owner authorized a HOME+MENU cold-start test after the
[pending-state preflight](mibox-recovery-cold-entry-preflight.md). The host
started the observation-only collector at 2026-11-14 14:19:50 Asia/Taipei.
The owner later reported another attempt and explained that the touch remote
could not invoke recovery with this combination. No recovery menu was reported.
Do not repeat this method without a new basis for reliable input.

## Observations and return

Baseline Android boot ID was f30c821a-8b2c-4ca0-9247-eb6b1d2203bc with the
original fingerprint and boot_completed=1. ADB disappeared, returned as device,
then disappeared again during the three-minute observation. No sampled C003
loader enumeration was recorded. A live read while connected observed boot ID
d7ea41be-d124-4074-b797-cb6f16b6e092, original fingerprint, and Android zygote/
system_server processes. The boot-completed property was empty at that read.
Those interim live queries were inspected in the tool transcript, not retained
as separate raw files; the automated USB/ADB trace remains the primary timeline.

The owner reported another power/remote attempt while follow-up observation
was in progress. Its exact start time is not independently captured. Do not
classify the extra USB disappearance as a spontaneous reboot or merge both
owner actions into one controlled test.

At 14:24:04, independent retained reads observed:

- ADB device state, serial 248243005297, transport_id 14.
- Boot ID 6d4f3f97-d576-4600-9c99-9d2814e07629.
- Original Xiaomi/casablanca_icntv/casablanca:4.4.2/KOT49H/2876:user/release-keys fingerprint.
- sys.boot_completed=1.

This establishes an Android-completed checkpoint after the owner attempts,
not continuous stability or a demonstrated exit from recovery. The host sent
no reboot, loader, input-injection, wipe, update or partition-write command.
Normal stock startup can perform its own persistent writes.

## Disposition

Remote HOME+MENU entry: **NOT DEMONSTRATED** with this owner's touch remote.
Owner reports this input method cannot invoke recovery. Ordinary BACK/UP/DOWN
IR events still have separate successful physical evidence; those do not
establish that a simultaneous recovery combination can be emitted.

Recovery functionality itself, an independent USB-loader entry, interactive
recovery console and physical partition restoration remain untested. A future
ADB reboot-to-recovery test would depend on working Android and would not
close the Android-independent rescue gate. Permanent installation remains
**NOT READY**; the previously proven RAM-only boot remains the usable custom
userspace path, subject to its documented limits.

Evidence directory: `artifacts/recovery-entry/20261114-141950/`.

- [Baseline](../artifacts/recovery-entry/20261114-141950/baseline.json)
- [USB/ADB events](../artifacts/recovery-entry/20261114-141950/events.jsonl)
- [Three-minute observer end, with ADB absent](../artifacts/recovery-entry/20261114-141950/final.json)
- [Subsequent Android-completed checkpoint](../artifacts/recovery-entry/20261114-141950/post-release-result.json)
