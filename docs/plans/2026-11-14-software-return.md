# Software return from custom RAM userspace

1. [x] Inspect current PID1, ADB credentials and exact stock restart evidence.
2. [x] Add a bounded PID1 control socket for checking and requesting normal restart.
3. [x] Verify unprivileged request handling, rejection and actual restart in QEMU.
4. [x] Build a separate offline candidate and record hashes and limitations.
5. [x] Boot the new candidate in RAM and independently verify Android return.

The initial RAM-booted PID1 had no management channel and ADB had no CAP_SYS_BOOT.
Do not replace PID1 live, use raw hardware writes, flash partitions or infer
hardware success from a QEMU restart. A new RAM boot is required for step 5.

Physical test completed after owner power recovery: Android boot ID
a97acb4d-364e-492b-8d7f-f8b8d27ce1df and boot_completed=1 verified.
The uploader now has explicit Baseline/Restart presets with separate pinned
hashes; Restart permits only full UploadAndBoot. VerifyOnly validates locally
without USB access, including a corrupt-image rejection check.

PASS: full 8 MiB RAM readback matched the Restart pin, custom boot ID
97939422-599d-44bf-b293-8f88aef935a8 and both executable hashes verified.
One software restart returned to stock Android boot ID
f30c821a-8b2c-4ca0-9247-eb6b1d2203bc with the original fingerprint and
boot_completed=1, without another owner power cycle. See
docs/mibox-software-return.md and artifacts/software-return/return-20261114-104707/.
