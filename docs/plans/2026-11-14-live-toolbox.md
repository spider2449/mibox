# Extend the running custom userspace

1. [x] Confirm the RAM-booted custom system and identify missing management tools.
2. [x] Add self-contained identity, uptime, process, mount and network diagnostics.
3. [x] Add a separate RAM-only self-test for the normal ADB UID, preserving the existing chroot test.
4. [x] Deploy an executable into /tmp through authenticated ADB and verify its hash.
5. [x] Exercise the new commands on the physical custom boot and retain results.

Keep the current PID1 and installed Android partitions intact. No network or
USB reconfiguration, eMMC mounts, persistence changes or reboot in this step.
