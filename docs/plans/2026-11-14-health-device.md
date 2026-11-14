# Health snapshot on the stock-kernel device

Scope: content-addressed standalone toolbox in the existing /tmp tmpfs only.
No reboot, root escalation, mounts, persistent installation or boot packaging.

1. [x] Inspect the current runtime: stock Android, boot completed; /tmp tmpfs.
2. [x] Verify /tmp is a writable directory without a symlink.
3. [x] Push the ARM toolbox into temporary Android scratch storage, pull it
   back and match SHA256; remove the exact temporary executable after testing.
4. [x] Run info and health with explicit shell exit markers; compare procfs
   identity and old-kernel memory fields; verify the boot identity is unchanged.
5. [x] Retain attempted-transfer provenance and document the blocker.

Evidence directory: artifacts/userspace-health-device/2026-11-14/.
This tests a standalone process under Android, not updated custom PID1 or a new
boot candidate. The existing RAM-toolbox uploader requires the custom OS marker
and is intentionally not used for the Android runtime.

## Initial RAM-path attempt: failed

The shell directory guard passed as UID2000, and /tmp was tmpfs. The actual
ADB sync push nevertheless exited 1 with remote Permission denied. No retry,
chmod, execution, readback, root escalation or SELinux change followed.
SELinux reports Enforcing; the precise access-control cause is UNKNOWN.
The failed path is `/tmp/mibox-toolbox-2e4f1dfd8f28`; post-attempt listing also
returns Permission denied, so existence/partial contents are UNKNOWN.

Attempted source: 511820 bytes, SHA256
`2e4f1dfd8f28c0bf52323a9e65abf314e1e1705505414cc7cc25fcdf99128512`.
Boot ID before and after: `ecdad7fb-31d0-4e02-adb5-863bdf0529d5`.
See `baseline.json`, `tmp-guard.json`, `destination-guard.json`, `push.json`,
and `post-push-inspection.json` in the evidence directory. ADB's progress text
claims one file pushed, but its exit code and remote error establish failure.

Follow-up inspection established /tmp mode 0765: shell's sdcard_rw group has
write but lacks directory search permission. This explains why test -w was
insufficient. It does not establish whether SELinux would also deny access.

## Completed physical health validation

Scope was revised to the project's previously used Android scratch directory,
`/data/local/tmp`, with a single temporary executable and no root escalation.
This writes a temporary file to /data; it is not RAM-only deployment.
Destination `/data/local/tmp/mibox-health-2e4f1dfd8f28` was checked unused,
pushed, pulled back, SHA256 matched, and chmodded 0755.

Health returned explicit shell exit 0 as UID2000 under Linux 3.10.33:
boot ID matched; PID1 init; rootfs root; MemTotal 877072 KiB;
MemFree 70296 KiB at observation. MemAvailable was absent in actual procfs,
and the new executable correctly reported UNKNOWN. Uptime was 14217.75 s.
The separate info command returned exit 1 because Android lacks /etc/os-release;
this is recorded as a limitation, not a successful info test.

The exact temporary executable was removed and absence checked. Boot ID stayed
unchanged. `result.json` records the completed result; `provenance.json` retains
source/readback SHA256. No reboot, mounts, security changes or boot-image edits.
This validates standalone health on the actual old kernel, not custom PID1,
independent boot, or a replacement kernel.
