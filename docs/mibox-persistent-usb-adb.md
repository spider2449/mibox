# Stock USB ADB persistence

Status on 2026-11-14: V3 PASSED unattended reboot validation. USB returned
automatically after a captured late startup reset. The hook finished, then
20 seconds of stable USB ADB passed. The active hook is V3; V1 and V2 failed
and were rolled back before this attempt. Original backups remain available.
This validates one reboot on the active system1 partition, not OTA updates,
switching system partitions or every future startup condition.

V3 uses only SettingsProvider. For 60 iterations it records uptime, adb_enabled,
runtime USB config/state and adbd state; when adb_enabled is exactly 0 it writes
1. It sleeps two seconds per iteration and exits afterward. It does not issue
USB property writes or adbd control commands during boot. The window is bounded
and does not override later deliberate settings changes after the hook exits.
Its 994-byte readback SHA256 is
4acab30d280fa931648db8d8bf8dfc1110488904bec498f0bc4dcd2095e61177.
Reboot evidence: artifacts/adb-persistence/verification-20261114-061848/.

V3 captured the missing transition in boot
856371d4-27c7-417a-b412-520e915deca8:

| Uptime seconds | adb_enabled | USB config/state | adbd | Action |
| --- | --- | --- | --- | --- |
| 89.48 | 1 | adb / adb | running | observe |
| 92.68 | 0 | none / none | stopped | restore setting to 1 |
| 97.33 | 1 | adb / adb | running | observe |

USB disconnected around host test second 98 and returned automatically by
second 103. This demonstrates a late startup setting reset and successful
SettingsProvider-only recovery. It does not independently identify which
process wrote the reset. The stock settings APK contains the previously
documented reset code; third-party apps also run ADB-related commands.
Source evidence: artifacts/adb-persistence/2026-11-14/v3-boot-progress.log.
Final full log: artifacts/adb-persistence/2026-11-14/v3-boot.log.
Automated result.json has Passed=true and RebootRequested=true. It verifies
a changed boot ID, current-boot hook completion, adb_enabled=1, USB config/state
adb, SELinux Enforcing, filesystem and partition read-only, then stability.
The hook is bounded to startup; it does not continuously fight later user
changes. Stock startup may briefly disconnect USB before automatic recovery.

Rollback succeeded as job 3149-1794608144250. Readback confirmed root:root,
0644, system_file label, /system read-only, partition read-only=1 and SELinux
Enforcing. Evidence: artifacts/adb-persistence/2026-11-14/rollback-state.txt.
The recovered v2-boot.log shows the hook completed and reported runtime config
adb, state adb, adbd running and gadget enable=1. This contradicts any claim
that the hook simply failed to execute; the later disconnect cause is UNKNOWN.

V2 reboot evidence: artifacts/adb-persistence/verification-20261114-061142/.
Boot ID changed to 7c9bc266-5af4-4731-949b-c6c9929982c9. USB ADB appeared early
in boot; Android completed boot around 76 seconds and the new hook started.
USB disappeared around 100 seconds and did not return within 180 seconds.
The last snapshot during the automated test contained only BEGIN and the new boot ID.
The explicit runtime property write is a possible cause, not a proven cause.
Manual recovery, log collection and restoration subsequently completed.

Follow-up at 06:09: USB access returned. Boot ID changed to
8a90eb47-a4cb-4543-b42a-4db84fc73193. The log contains this same boot ID,
adb_enabled=1, persist.sys.usb.config=adb and MIBOX_ADB_HOOK_DONE.
Current-boot checks and 20 seconds of stable USB ADB passed, with /system and
the partition read-only and SELinux Enforcing. Evidence is under
artifacts/adb-persistence/verification-20261114-060858/ (RebootRequested=false).
The owner subsequently confirmed manually enabling ADB. V1 therefore did not
achieve unattended USB recovery, despite the successful hook log.

V2 also writes sys.usb.config=adb and ctl.start=adbd, then records runtime
config/state, service state and gadget enable. The device's actual /init.usb.rc
confirms the sys.usb.config=adb action enables the gadget and starts adbd.
V1 did not log runtime values, so its precise failure mechanism is UNKNOWN.
The read-only diagnostic is artifacts/adb-persistence/2026-11-14/init-usb-policy.txt.
V2 readback is 932 bytes, SHA256
95e7381b0e5c43450c861457ca66108ffdccf6ef998077b3f87ad5b270507768.
Installation succeeded as job 3693-1794607862552. Original backups are unchanged.

The supplied same-model article is at
https://blog.csdn.net/boaman/article/details/85205014 . Device reads, rather
than the article, establish that this box mounts /dev/block/system1 at /system.

The existing root xiaomi-post-boot service invokes
/system/etc/init.post-boot.sh after sys.boot_completed=1. The installed script
preserves the original backup-version command and appends a 20-second delayed
write of Settings.Global.adb_enabled=1 and persist.sys.usb.config=adb.
Its log is /data/local/tmp/mibox-adb-boot.log.

The original is 76 bytes, SHA256
d8b90e155a231ebc1a5fb76bf101855b18870c7b46585c94e7d2c48e09e990a6.
The installed script is 652 bytes, SHA256
9ca0c670db8a2856902c48b5edf9be49037e022b83b59303080996ab93de729b.
Host backups are under phone-tools/backup/adb-persistence/.
Device backups are under /data/local/tmp/mibox-adb-persistence-v1/.

Installer src/bin/mibox-persist-adb.rs uses the previously confirmed temporary
root wrapper. It temporarily clears the system1 partition block read-only flag,
remounts /system, replaces the script atomically, and restores filesystem and
partition read-only state. A separate guard restores protection if the worker
is interrupted. Readback confirmed root:root, mode 0644, system_file SELinux
label, /system read-only, block read-only=1, and SELinux Enforcing.

Installation result: MIBOX_ADB_WORKER_OK, job 4381-1794607315846.
Evidence: artifacts/adb-persistence/2026-11-14/.
Reboot request evidence: artifacts/adb-persistence/verification-20261114-060422/.
Before reboot ID: 8c1355b4-46e6-4e5f-8429-4786e8b45c3d.

After USB access is restored, collect the new boot ID, hook log, adb_enabled,
USB configuration, mount protection and SELinux mode. These distinguish a hook
failure from a later vendor reset or USB enumeration failure. Do not infer the
cause solely from an empty adb devices listing.

Rollback, once USB ADB is available:

```powershell
& .\phone-tools\platform-tools\adb.exe -s 248243005297 shell /data/local/tmp/mibox-persist-adb --rollback
```

The rollback validates the known script before restoring the original script.
It does not change the current ADB setting. It requires the temporary root mechanism to remain
available. OTA updates or switching the active system partition may replace or
bypass this hook.

## Hot-plug after a flash boot (Dev13), 2026-11-27

Booted from flash without the PC (boot `f5750d1c…`), USB plugged in about 28
minutes later. The gadget went DISCONNECTED -> CONFIGURED (high-speed, `ffs`);
`adb devices` listed `248243005297 recovery … model:MiBOX1S` and
`adb shell` answered as uid 2000 with the same boot ID, kernel 3.10.99. The
kernel logged one `ep0_do_stall … req 80.06 protocol STALL` during
enumeration (a refused descriptor request), with no effect on ADB.
