# Read-only physical runtime follow-up

At 2026-11-14 10:06 Asia/Taipei, the RAM-booted custom userspace was still
reachable through authenticated USB ADB. All eleven bounded read-only queries
completed with host exit code 0 and no timeout; their actual outputs were also
inspected because the stock shell exit status alone is insufficient evidence.

Evidence: [observations.json](../artifacts/runtime-followup/20261114-100600/observations.json).

- Boot ID before and after: dd2afb3c-091b-4e84-bfde-d468ef3045b1, matching the
  original physical RAM boot.
- Uptime advanced from 721.35 to 722.12 seconds (approximately 12 minutes).
- OS marker remains mibox-custom; kernel remains 3.10.33.
- PID1 is root init; adbd remains its UID2000 child.
- Mounts contain only rootfs and virtual filesystems, with no block filesystem.
- MemTotal is 877072 kB; MemFree at this observation is 847944 kB.
- eth0 remains down with UNKNOWN carrier and no IPv4 routes reported.

These snapshots show the same boot was alive and responding at this checkpoint.
They do not establish continuous service health, load stability, memory trends,
or complete watchdog coverage. The raw PID1 status includes an implausible
VmLib value of 4294967192 kB; its interpretation is UNKNOWN and it is not used
as a memory-usage measurement.

No device files were written, no filesystems mounted, and no reboot or USB/network
reconfiguration was performed. Persistent installation, replacement kernel,
HDMI/audio, network operation and software-only return remain unverified.
