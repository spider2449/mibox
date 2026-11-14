# Scoped Windows loader driver preparation

1. [x] Confirm loader 1B8E:C003, problem code 28, no service/INF and non-elevated host token.
2. [x] Download official Zadig 2.9 and verify Valid Akeo Consulting Authenticode signature.
3. [x] Prepare exact-device WinUSB preset and a signature-checked interactive launcher.
4. [x] Build a read-only WinUSB descriptor/identify probe; do not send image data.
5. [x] Obtain required Windows administrator/UAC action, then verify the target driver.

This uses the Microsoft WinUSB driver for only USB\\VID_1B8E&PID_C003. Do not
replace the normal 18D1:D002 ADB driver, hubs, HID devices or unrelated interfaces.
Zadig's documented preset supports staging a device package before it is plugged.
The owner installed the actual C003 device using Install Driver. Live verification
confirmed WinUSB, oem40.inf, problem code 0 and interface GUID
d925a7f0-61a4-4018-bcd3-f3e5225f3532. Identify returned 00-08-00-10;
a fixed 64-byte read at saved loadaddr 0x82000000 also succeeded.
Evidence: artifacts/usb-loader-protocol/2026-11-14/.
