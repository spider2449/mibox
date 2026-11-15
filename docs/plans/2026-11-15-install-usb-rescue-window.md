# Install and validate a pre-OS USB rescue window

Date: 2026-11-15. Owner explicitly asked to implement the proposed window.
Android return is not an acceptance criterion. Preserve existing boot images
while establishing recovery access; never damage a partition as a test.

1. [x] Authenticate current custom RAM session and SSH host key; collect current
   environment identity and a complete read-only, device-hashed backup.
2. [x] Resolve environment layout from backup, actual loader read/save code and
   reference source; refuse ambiguous or redundant formats.
3. [x] Implement a bounded environment patch changing only pre-OS USB entry;
   preserve all unrelated bytes, validate CRC and show the exact command diff.
4. [x] Test wrong content/size/CRC, symlinks, interruption and readback
   failure using disposable files before enabling a real-device write.
5. [x] Install only once the format/target/write path are established and retain
   complete readback plus a recovery copy. Do not overwrite the bootloader.
6. [ ] Verify startup without host takeover and startup with host takeover,
   complete pinned RAM rescue upload/readback and independent custom identity.
7. [ ] Record limits: this protects custom kernel/PID1 failures while bootloader
   and environment remain intact, not arbitrary eMMC or power-loss failures.

Physical power removal/reconnection, if necessary, requires owner action.
Do all host preparation first. Retain failed evidence and do not auto-retry
persistent writes or mode transitions.

## Installation checkpoint

- Original 4 MiB before/after device hashes and host hash match
  `e85c14d547bde485ded38f41050f197ba33dfe24cc543bec61f11eafea2f812a`.
- `inspect-env-storage.py` verifies the exact loader's named `env` partition
  read/write routines, 32768-byte extent and 32764-byte CRC payload.
- Payload prepends `update 10000;` to `preboot`, preserving all other values
  and every byte past offset 32768. Expected full modified hash:
  `6142e34ffd40682add106f466a4859365c15ad19bc7cc8d74335fd03f464ca2c`.
- Native regular-file tests: 10/10 passed. Physical ARM helper `--check` passed.
- Physical installation, fsync/cache flush and full 4 MiB readback passed;
  independent second collection matched the expected modified hash. Reports:
  `artifacts/restoration/2026-11-15/window-install-20261115-175853/` and
  `artifacts/restoration/2026-11-15/environment-20261115-175932/`.
- GNU stat/ls device numbers are unreliable on this old kernel; BusyBox stat
  corroborated actual device numbers. The apparent /dev/env 0:0 was a userland
  reporting failure, not proof of an invalid kernel node.
- Persistent console was cleanly stopped. A normal restart from custom boot ID
  `b5567c71-9f2e-4d73-9239-0a80e7120ab3` exposed C003 with identify 00-08-00-10.
  No reboot-to-loader reason was requested. Completed RAM rescue reload:
  `artifacts/rescue-boot/20261115-175944-393/`.
- RAM rescue reload PASS: all 8388608 bytes read back with pinned Console SHA256,
  elapsed 1311.375 seconds, custom PID1/tool hashes matched and new boot ID
  `226a6893-4792-4ea2-8f25-f4211ff09409`. SSH and the existing persistent console
  are ready at 192.168.1.222. Post-boot full env backup still matches the installed
  hash, demonstrating retention across this ordinary restart.
- No cold-power or host-disconnected startup result yet. Do not count the
  ordinary software restart as a completed physical cold-start test.
- Owner availability for a power cycle was requested while transfer ran; no
  response yet. Keep the current custom console running until an observer is
  armed and owner action can be coordinated. Host preparation is complete.
- Machine-readable summary:
  `artifacts/restoration/2026-11-15/usb-window-physical-summary.json`.
