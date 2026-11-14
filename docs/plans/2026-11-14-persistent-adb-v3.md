# Observe and repair late ADB setting resets

1. [x] Confirm v2 rollback and inspect stock setter and current USB Manager.
2. [x] Preserve v2; prepare bounded SettingsProvider-only startup monitoring.
3. [x] Build and install v3 with original backup and protection checks.
4. [x] Reboot; capture reset timing and automatic reconnection without manual enable.
5. [x] Verify stable connection after monitor exits, or roll back on failure.

V3 monitors for 60 iterations with 2-second sleeps after boot completion.
It changes only adb_enabled=0 to 1. It never forces sys.usb.config or adbd.
The hypothesis of a late vendor reset is not yet proven. Third-party Shafa
also issues ADB commands; the captured log does not establish it disables USB.

Installed readback: 994 bytes, SHA256
4acab30d280fa931648db8d8bf8dfc1110488904bec498f0bc4dcd2095e61177.
Worker OK: 3498-1794608289058. Reboot verification timeout is 360 seconds;
SettingsProvider invocations add overhead beyond the 120 seconds of sleeps.

PASS: verification-20261114-061848/result.json records a changed boot ID,
hook completion, read-only/SELinux protections and 20 seconds of stability
after the hook exits. At uptime 92.68s saved=0, USB none and adbd stopped;
at 97.33s the restored setting is 1, USB adb and adbd running.
