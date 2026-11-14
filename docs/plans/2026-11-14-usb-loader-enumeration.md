# Software USB-loader enumeration only

1. [x] Inspect saved boot graph and pinned reference source; note enumeration cancels timeout.
2. [x] Confirm owner can power-cycle if software return is unavailable.
3. [ ] Record baseline USB state and request adb reboot usb_burning once.
4. [ ] Observe actual USB IDs and driver state without opening a loader session.
5. [ ] Return to Android, verify boot ID/ADB and preserve evidence.

No image upload, memory writes, flash commands, environment writes or driver
installation. Windows currently has no found historic 1B8E device or matching
WorldCup/Amlogic OEM INF. That search does not prove all driver mechanisms absent.
The public source reference is not a proven match for the Xiaomi bootloader.
Owner explicitly confirmed they can operate the box power before this test.
