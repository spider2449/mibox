# Custom-system rescue without Android

Updated 2026-11-15. The owner requires the custom system, not an Android return.
The rescue objective is to reload or repair that custom system after a failed
kernel/PID1 boot. Independent cold entry remains **NOT VERIFIED**.

## Installed USB window checkpoint

The pre-OS window is now installed: only `preboot` gained `update 10000;`.
Original environment backup, exact-loader eMMC layout audit, 10 passing host
tests, physical updater check, fsync/cache flush and full readback are retained.
A separate full device/host hash comparison matched the modified 4 MiB image:
`6142e34ffd40682add106f466a4859365c15ad19bc7cc8d74335fd03f464ca2c`.
Boot images and bootloader image were not replaced.

Normal restart from the custom OS exposed C003 and verified identify 00-08-00-10,
without requesting a USB reboot reason. The first rescue reload **PASSED**:
all 8388608 bytes matched the pinned Console image, custom PID1/tool hashes
matched, and boot ID changed to `226a6893-4792-4ea2-8f25-f4211ff09409`.
Evidence: `artifacts/rescue-boot/20261115-175944-393/`. SSH and the existing
persistent console are ready at 192.168.1.222. A second complete env backup
after this boot still matches the installed hash. Cold-power entry and startup
without host takeover still need physical testing. The numeric window argument
has not yet been established as a measured duration.

The fixed updater `target/rescue-window/rescue-env` supports `--check`,
`--install`, `--remove` and explicit recovery of a recognized interrupted
original/window prefix via `--recover-original`. The whole 4 MiB target must
match its embedded allowed state, including the unchanged tail. `--remove`
requires the exact installed image; it must not overwrite a later changed
environment. There is no arbitrary target or payload argument in the device
build. Host orchestration is `scripts/install-rescue-window.py` under WSL.
The region is single-copy; power-loss atomicity is not established.

See [installation plan and checkpoints](plans/2026-11-15-install-usb-rescue-window.md).
[Physical summary](../artifacts/restoration/2026-11-15/usb-window-physical-summary.json).

### Operational implications

The USB host can cancel the bootloader deadline during enumeration/identify.
With the PC attached, startup may remain in C003 until the host loads a RAM
image. Keep power and USB attached during a transfer. With no USB host, the
deadline expires and the existing boot path continues: on 2026-11-16 the owner
cold-started the box with the PC USB disconnected and it returned to Android
(one observation, no host-side log; the window's duration is unmeasured). Existing boot images still select the original
system; installing this window did not permanently install the custom OS.

An independent cold-start test requires owner-controlled power removal and
reconnection while the host observer is armed. It is not interchangeable with
the already observed ordinary software restart. Do not test by corrupting a
boot partition. Successful RAM reload alone also does not demonstrate repair
of a persistent custom boot image.

## Fastboot audit

The exact expanded stock loader SHA256 is
`99f701ac15a155aa07b7204d240b82a0a5c91457513ae1e246146e3f8b8753a2`.
The hash-checked audit finds 89 plausible command registrations and reproduces
all six registrations from the earlier command-address report. None is fastboot.
Case-insensitive scans find zero `fastboot`, `getvar:` or `download:` strings.
The four `flash:` hits occur in imgread help text about reading from flash;
they are not evidence of the fastboot flash protocol.

The retained exact kernel reboot switch has no `fastboot` or `bootloader`
argument case. The verified argument is `usb_burner_reboot`, selecting the
Amlogic USB loader. Do not assume `adb reboot bootloader` selects fastboot.
The current host `fastboot devices -l` query returned no devices; the box was
answering as the custom RAM OS over ADB at that time. An empty host list in
this state is not a fastboot capability test. Negative static evidence also
cannot rule out every hidden implementation; fastboot support remains UNKNOWN.

Reproduce: `python3 scripts/inspect-loader-fastboot.py` under WSL.
[Audit report](../artifacts/restoration/2026-11-15/loader-fastboot-audit.json).

## Loader-to-rescue launcher implemented

`scripts/rescue-boot.ps1` defaults to local `Check`. `WaitAndBoot` waits for
one healthy C003 USB device, verifies loader identification `00-08-00-10`,
and refuses a simultaneously present target ADB transport. It uploads the
existing pinned Console candidate using the verified control path, requires
complete 8 MiB readback/hash, boots it, and verifies custom OS/PID1/boot UUID
and the exact `/init` and `/bin/mibox` hashes.

It issues no Android reboot, partition write or environment command. It does
not require Android properties, Android return or an Android baseline. It can
reload RAM once a compatible loader is reachable; it does not create that entry
or implement custom-image partition repair. Its proof always leaves
`IndependentColdEntryVerified=false` because entry origin is not demonstrated.

## Cold entry verified (2026-11-15)

Physical cold power with the host attached exposed C003 directly, identify
00-08-00-10, on two cold starts. The preboot USB window is therefore proven
on a physical cold start. A full pinned Console RAM upload/readback and bootm
completed from that C003 entry with no Android session anywhere in the chain
(evidence `artifacts/ram-boot/`, `artifacts/console-ssh/launcher-20261115-212455`):
cold power -> C003 -> custom console -> authenticated SSH -> persistent
userspace, all without Android. The running custom system was reachable by
ADB reporting the `recovery` USB class; `cat /etc/os-release` confirmed
`ID=mibox-custom`. That closes the cold entry question for the
host-attached case. Host-disconnected cold-start continuation was later observed
once (2026-11-16, owner report): window expiry, then Android. Bulk OUT transfer was
repaired on 2026-11-16 (host PipeID bug; full load 23 s with `-Bulk`): see
mibox-usb-loader-protocol.md.

```powershell
powershell -NoProfile -File scripts/rescue-boot.ps1 -Action Check
# Only after an independently established C003 entry:
powershell -NoProfile -File scripts/rescue-boot.ps1 -Action WaitAndBoot
```

Local check passed. Fourteen isolated orchestration fixtures passed, covering
local hash failure, absent/ambiguous/unhealthy USB, unexpected loader identity,
child failure, stale ADB, incomplete/bulk transfer, incorrect or incomplete
runtime identity, wrong executable hash and the successful mocked workflow.
These are host tests, not a new physical RAM boot or repair result.
[Fixture results](../artifacts/restoration/2026-11-15/rescue-launcher-tests.json).

## Pre-OS USB window candidate

The exact loader has a timeout path returning from its USB loop to the caller.
The timer routine reads counter register `0xc1109954` and divides elapsed
counter ticks by 1000; this follow-up does not establish its physical frequency.
Do not assume a measured duration from an `update` numeric argument.

The identify request 0x20 clears the very same timeout-state word that the
poll checks (derived link address `0x8f8c4828`). Thus host identification can
hold the loader past its initial deadline. This supplies exact binary evidence
for one cancellation path, and explains why a simple bounded-window assumption
is insufficient. It does not establish every standard-descriptor handler.

A USB window before the main `bootm` can be placed independently of the custom
kernel and userspace while still depending on intact bootloader/environment.
Its installation, host-disconnected continuation (one owner observation) and
host-attached cold-start takeover have since been physically observed. The initial audit preceded installation;
the checkpoint above records the later installation and warm restart.
Reproduce: `python3 scripts/inspect-rescue-window.py` under WSL.
[Window audit](../artifacts/restoration/2026-11-15/usb-rescue-window-audit.json).

The initial audit performed no device mutation. The later installation wrote
only the first 32768 bytes of env, verified the full partition, and requested
one normal custom-system restart. No bootloader image was modified.
