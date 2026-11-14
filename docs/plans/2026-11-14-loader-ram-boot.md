# Validate temporary USB RAM boot

1. [x] Verify actual C003 WinUSB binding and read loader identity.
2. [x] Trace bounded READ_MEM against pinned reference; read 64 bytes at the device's saved loadaddr.
3. [x] Trace write completion/cache handling and normal reset semantics before implementing commands.
4. [x] Implement restricted RAM transfer with complete readback verification and retained evidence. Complete 8 MiB image SHA256 matched through 64-byte control transfers.
5. [x] Validate Android return via owner power cycle, then attempt the verified candidate through RAM only. Custom PID1/userspace and physical FunctionFS ADB verified; see docs/mibox-ram-boot-success.md.

No storage, erase, key, environment-save or partition-write commands. Public
reference commit c0b0b8cc9bd5901ced2e929ea87b99fae52d528c is not established
as the exact Xiaomi bootloader build. Runtime result is PASS for this temporary
RAM boot; persistent installation remains unverified.

Live reset attempt: control transfer completed, but Android did not return;
C003 remained present and subsequent identify timed out. Owner power recovery
completed: Android boot ID 8728abd4-158d-4d17-9ff3-18caf398cc83, ADB device,
boot_completed=1. Do not treat USB transfer completion as command execution success.
Reference flush_cpu_cache is an empty macro; no cache-coherency claim is made.

512-byte control read timed out, but subsequent identify/64-byte RAM read
worked. Switched to 64-byte control transfers. A later bulk read diagnostic
(request 0x12, 16-byte address/length payload, actual IN endpoint 0x81)
timed out with Win32 121; subsequent identify failed. No bulk pattern write
was reached. Bulk image actions are disabled pending protocol investigation.
No candidate boot command had been sent at that diagnostic checkpoint. Second
power recovery completed with Android boot_completed=1 and normal ADB.

The next attempt uses only the verified 64-byte control channel. UploadAndBoot
pins the 8 MiB host image, writes and compares every block, checks the complete
readback SHA256, then sends the fixed bootm command in the same open session.
This avoids re-reading unchanged RAM in a separate boot invocation. No command
is sent on incomplete transfer or verification failure. The earlier reset used
512 command bytes; this attempt limits command data to 64 bytes. Actual boot
acceptance remains UNKNOWN until independently observed.
