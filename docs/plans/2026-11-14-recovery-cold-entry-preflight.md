# Cold recovery-entry preflight

1. [x] Identify automatic recovery argument/command sources in exact firmware.
2. [x] Read current pending-command state with the established temporary-root diagnostic.
3. [x] Prepare an observation-only USB/ADB collector without reboot or loader commands.
4. [x] Record remaining gates and coordinate owner power/remote action only after preflight.

No recovery entry, partition write, environment update, reset or wipe in this step.
Temporary-root diagnostic may write its usual scratch executable/results in /data/local/tmp.

No cache recovery directory; selected env flags absent, upgrade_step=0.
Current env prefix device/host SHA256 and CRC verified. No claim that all
automatic startup sources are ruled out. Observer BaselineOnly passed;
owner subsequently authorized and attempted cold entry. No recovery menu was
reported; owner touch remote cannot invoke the combination. Android-completed
checkpoint confirmed afterward. See `docs/mibox-cold-recovery-attempt.md`.
