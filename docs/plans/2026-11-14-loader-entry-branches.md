# Exact loader entry branch audit

1. [x] Resolve update and reboot-mode handlers from validated command registrations.
2. [x] Inspect exact handler branches and distinguish USB wait from storage-burning commands.
3. [x] Record entry dependencies, side effects, and remaining UNKNOWN values without physical execution.

Confirmed reason mapping and a nonzero startup-state override selecting update.
How to establish that state on cold boot remains UNKNOWN. Timer thresholds
and guarded expiration audited, but time units remain UNKNOWN.
See `docs/mibox-loader-entry-branches.md`.

Offline only. No reboot, remote input, flash command, media preparation or env change.
