# Independent rescue entry follow-up

Date: 2026-11-15

Objective: boot and repair the custom system without relying on Android.
Returning to or restoring Android is not a required outcome. Do not damage a
boot image to test rescue entry.

- [x] Review exact loader branches, stage-one boot information, remote evidence,
  recovery interface and the unsuccessful touch-remote cold-start attempt.
- [x] Recheck Xiaomi IR guidance: HOME+MENU at power-on is general guidance,
  not exact-device proof and not evidence of a recovery shell.
- [x] Reproduce pinned offline loader, stage-one and IR comparison audits.
- [ ] Establish whether the owner has an alternative compatible IR transmitter.
- [ ] With a supported input method, arm host USB/ADB observation before an
  owner-operated cold start. Keep existing Android intact and supply no update media.
- [ ] If recovery appears, identify its USB transport and available interface
  without selecting wipe, update or system switching. Sideload alone does not pass.
- [ ] Demonstrate access to the exact pinned RAM rescue runtime without Android,
  and verify its identity independently. Custom-image repair is a separate gate.
- [x] Audit fastboot candidates in the exact expanded loader and query the host
  transport without rebooting. No fastboot command or string found; support UNKNOWN.
- [x] Implement a loader-to-custom-RAM launcher with no Android baseline/reboot.
- [x] Validate launcher rejection paths using isolated fixtures and check the
  pinned rescue candidate locally before device operations.
- [x] Audit a bootloader USB window before OS execution, including timer and
  descriptor-triggered timeout cancellation. Do not install unverified settings.
- [ ] Interpret the 2026-11-14 bulk probe failure against restored reference
  bulk framing (usb_pcd.c RD_LARGE_MEM three-stage flow) and, only with owner
  coordination and the loader in a recoverable state, run the single-shot
  read-only bulk probe `scripts/Probe-MiboxUsbLoaderBulk.ps1`. One attempt,
  full evidence, no retry; a wedged loader requires owner power recovery.
  DONE 2026-11-15: with correct framing the EP0 command stage is accepted but
  the bulk data stage still fails and wedges the loader; the configuration
  descriptor dump (Probe-MiboxUsbConfigDescriptor.ps1) proves bulk endpoints
  0x81/0x02 exist with MPS 512, so the failure is in the loader build's bulk
  data path. Verdict: bulk unusable, control 64-byte is the only channel.
- [x] Verify cold-power loader entry: two cold starts with the host attached
  exposed C003 directly with identify 00-08-00-10, confirming the installed
  preboot USB window on a physical cold start. Host-disconnected cold-start
  continuation (window expiry then normal boot) remains unobserved.

## Path decisions

1. IR preboot recovery: supported by the exact loader; physical trigger and
   usable rescue interface remain unverified. Previous touch-remote failure
   must not be counted as a successful entry or repeated without new evidence.
2. Cold USB/Boot ROM: no proven host-only entry. Android ADB restart and custom
   userspace restart are working-system-dependent routes. USB enumeration alone
   does not establish the existing C003 protocol or safe RAM execution.
3. Stage-one external reader: SD/MMC-style, not demonstrated USB mass storage.
   The owner has no accessible SD slot; a USB card reader is not a substitute.
4. A bootloader USB window before OS execution could survive custom kernel/PID1
   failure while the bootloader and its settings remain intact. Its installation
   and cold-start behavior require verification; it is not an established path.

Current decision: independent rescue NOT READY. No reboot, flash, environment
write, register write, firmware package or hardware modification is required
for the offline follow-up.

Sources: ../mibox-loader-entry-branches.md, ../mibox-stage1-boot-info.md,
../mibox-cold-recovery-attempt.md, ../mibox-recovery-interface.md,
https://www.mi.com/service/box/update .

## Follow-up results

All three scripts completed with exit code 0 under WSL Ubuntu-24.04:
`inspect-loader-entry.py`, `inspect-stage1-boot-info.py`, and
`compare-ir-decoders.py`. Regenerated tracked reports have no Git diff.
The startup field still has no established owner-controlled cold trigger.
The modeled IR identifier 0x8603 has a matching checksum but no matching
entry in the exact kernel table; waveform equivalence remains unproven.
This supplies no basis to invent a button mapping or send a raw IR code.

An alternative-transmitter availability question is pending. No device
connection, reboot or storage operation was performed in this follow-up.

Later execution: owner removed Android return as a goal and authorized rescue
implementation. Added the direct C003 launcher, 14 passing isolated fixtures,
the exact fastboot audit and the USB timeout/identify-cancellation audit.
Authenticated read-only USB queries confirmed the existing custom RAM session;
no reboot or persistent storage operation was performed. Local Console image
validation passed. Cold entry and physical repair remain unverified. See
../mibox-independent-rescue.md for current behavior, evidence and remaining work.

Subsequent implementation installed the preboot USB window after a complete
current backup, exact-loader layout audit and 10 passing updater fixture tests.
Ordinary restart -> C003 -> complete pinned RAM rescue reload -> new custom
boot ID and usable SSH console passed without an Android session. Full env
readback after restart matches the installed image. Physical cold-power entry
and host-disconnected continuation remain pending owner action. Installation
details: 2026-11-15-install-usb-rescue-window.md.
