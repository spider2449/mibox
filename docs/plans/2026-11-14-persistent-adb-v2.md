# Restore USB ADB after stock startup

1. [x] Confirm owner manually restored ADB after v1 reboot.
2. [x] Read actual init.usb.rc property triggers with temporary root.
3. [x] Preserve v1 and add explicit runtime USB config and adbd start to v2.
4. [x] Build, install and verify exact bytes and restored protections.
5. [ ] Reboot and observe automatic USB return without owner intervention.
6. [x] Record evidence and remaining limitations.

Reboot test FAILED: USB appeared early, then disappeared around hook execution.
Next: restore access, collect log, roll back to original before further changes.

Completed: owner restored access, full log saved, original script restored.
Pinned SHA256, owner/mode/label and read-only/SELinux protections verified.
Persistence is UNSOLVED; both attempted hooks have been removed from the device.

Do not claim that the specific failed trigger is proven: v1 logged saved
settings but not runtime USB/adbd state. V2 records these missing values.
