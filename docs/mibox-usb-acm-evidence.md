# USB ACM transport: packets verified, handoff NOT READY

USB ACM exposed COM6 on Windows and exchanged fixed messages in both directions.
However, clean restoration is not established: the latest test showed a reset
and incomplete device-side logs. Live mode-switch experiments are disabled in
the current Rust source pending retained-log and driver investigation.

## Test sequence and verdicts

### First identity: 18d1:4e21

The device entered ACM mode, but Windows matched Google's oem0.inf to the exact
hardware ID USB\VID_18D1&PID_4E21 and loaded Android ADB Interface instead of
usbser. No COM endpoint was found. Original USB state was later read back.
Evidence: artifacts/usb-acm/20261113-223609/.

### Second identity: 18d1:4e41

Both IDs occur in the original init.amlogic.usb.rc. The host OEM INF inventory
had no exact 4e41 match. With class/subclass 02/02 and protocol 01, Windows
created USB Serial Device (COM6). Microsoft documents automatic usbser matching
for CDC class/subclass 02/02:
https://learn.microsoft.com/en-us/windows-hardware/drivers/usbcon/usb-driver-installation-based-on-compatible-ids

The host received MIBOX_ACM_READY, sent MIBOX_HOST_PING, and received
MIBOX_DEVICE_ACK. Final device-side readback matched the saved USB configuration,
and ADB shell answered. But the separate restore process reported EBUSY during
an overlapping operation. Boot ID was not captured before this test, so a clean
same-boot rollback cannot be claimed. Evidence and assessment:
artifacts/usb-acm/20261113-223820/.

### Third run: output-close/flush investigation

The protocol again exchanged packets through COM6. This revision stopped
announcements after the ACK and added tcflush before closing the gadget tty.
Afterward, uptime was observed at 76.32 seconds and the device state directory
had no restored marker, only the rollback-armed log. These observations indicate
an unexpected reset during the test, but its cause is UNKNOWN. In particular,
there is no retained panic log yet proving tcflush or a specific driver caused it.

The original host result incorrectly classified returning ADB as successful
restoration. That pass verdict is superseded by assessment.json in
artifacts/usb-acm/20261113-224055/. Packet transport is verified; clean handoff
is not. Windows later recorded ADB arriving at 22:41:44 and disappearing again
at 22:43:02; the cause of that later removal is also not established.

No boot partitions, boot variables, Android USB properties, SELinux policy or
host ADB drivers were intentionally modified. Only runtime gadget attributes
and scratch test files were written. Windows automatically created its USB
device/COM-port records as part of enumeration.

## Corrective changes

- Normal launch in mibox-usb-acm-test is now disabled in source. The retained
  internal restore mode is not an instruction to repeat the experiment.
- The tcflush operation was removed from current source. No further live USB
  switching was performed after detecting the reset.
- The PowerShell test now records before/after Linux boot IDs and requires the
  device-side verified restoration marker in addition to packets and ADB.
- Those new host checks passed syntax validation, not a new hardware run.
- A read-only crash query was added to mibox-read-platform, but its upload was
  blocked when the device disconnected. It has not yet collected pstore evidence.

## Optional init support

src/usb_console.rs implements the observed ACM attribute recipe. The init only
attempts it when kernel command line includes mibox.usb_acm=1. Ordinary-process
mode returns before USB code; the default PID1 console remains /dev/console.
On setup failure it attempts to restore its snapshot and falls back to that
console. This code has NOT executed as PID1 on the actual box.

The updated init passed the 8-stage generic QEMU test with USB requested but no
Android gadget driver available, verifying the UART fallback and reaper/console
behavior. It does not validate gadget teardown, physical driver stability or
actual custom-system boot.

## Next step

Follow-up: USB returned after the owner re-enabled/clarified the ADB menu state,
and /p/console-ramoops was collected read-only. It contains a boot-time CPU
frequency warning, not a USB-specific panic explaining the reset. See
docs/mibox-adb-reset-policy.md for the identified stock initialization policy
that can turn ADB back off after restart. The cause of the ACM test's incomplete
restore remains unresolved; no more mode-switch testing has been performed.

Reconnect USB and first acquire /p or /sys/fs/pstore crash evidence read-only.
Then inspect the legacy gadget close/disconnect/flush paths. Do not package or
flash a custom system, or repeat mode switching, on the strength of packet
exchange alone. The remaining loader/recovery gates also remain unresolved.
