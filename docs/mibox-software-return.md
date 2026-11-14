# Software return preparation, 2026-11-14

Status: physical RAM boot and software return to Android PASS for the exact
candidate below. The box is now running stock Android. The initial offline
checkpoint is retained below as historical context.

## Physical result

After owner power recovery, Android boot ID was
a97acb4d-364e-492b-8d7f-f8b8d27ce1df, with boot_completed=1. The explicitly
selected Restart candidate was uploaded through the verified 64-byte control
channel. All 8388608 bytes were compared and the complete RAM SHA256 matched
5608fa36caa28a7acf7a647b53db5d2775aaceb44730896f87da03f8ba6047fa before bootm.
Evidence: [upload result](../artifacts/software-return/physical-20261114/upload-and-boot.json)
and [progress](../artifacts/software-return/physical-20261114/verified-progress.txt).

The custom system appeared with boot ID 97939422-599d-44bf-b293-8f88aef935a8.
Pulled /init and /bin/mibox matched the new manifest hashes, respectively:

- 6ae13b3ed03864432edc4ca0f9ed8f9b46f6d6e6eeba690cf77dbbac0bc8e780
- 3e2d9a45aeff3d6b0bf727b1d1aadd31f8c776bf30fe62bf053ae3ac8ad240ce

PID1 was root init; --check returned READY for that boot ID. The host sent one
normal restart request at 10:47:08 Asia/Taipei. Its ADB output was empty, so no
acknowledgment-success claim is made. USB ADB disappeared and returned in the
device state. At 10:48:23, independent observations confirmed boot ID
f30c821a-8b2c-4ca0-9247-eb6b1d2203bc, original fingerprint
Xiaomi/casablanca_icntv/casablanca:4.4.2/KOT49H/2876:user/release-keys,
and sys.boot_completed=1.

[Physical return result](../artifacts/software-return/return-20261114-104707/result.json)
and [transport/Android events](../artifacts/software-return/return-20261114-104707/events.jsonl)
establish device execution separately from QEMU. No owner power cycle was needed
between this custom boot and Android return. The test tools issued no partition
write, erase or environment-save command. This is one successful restart, not
a stress test or proof of permanent-install restoration. Android can perform
its own routine persistent writes during normal startup.

## Initial baseline could not use the new interface

Read-only evidence in
[current-runtime-blocker.json](../artifacts/software-return/2026-11-14/current-runtime-blocker.json)
confirms the original custom boot ID dd2afb3c-091b-4e84-bfde-d468ef3045b1,
UID2000 shell with zero effective capabilities, and no /dev/mibox-control.
The original PID1 source has no restart handler or property service. Uploading
a new toolbox cannot add privileges or update the already running PID1.
No restart workaround was attempted inside that original RAM boot. Owner power
recovery enabled the later new-candidate test documented above.

## New RAM control interface

The new PID1 owns /dev/mibox-control in the root-owned devtmpfs. Kernel
SO_PEERCRED limits accepted clients to UID0 and UID2000; the client also verifies
that the server is root PID1. Only CHECK and a normal RESTART with the current
boot ID are accepted. Requests are limited to 128 bytes and a two-second total
read deadline. The listener closes rejected connections and remains available.

Before either operation, PID1 checks the custom OS marker, RAM root, exclusively
RAM/virtual filesystem types, and stock Meson6 compatible plus kernel 3.10.33.
Generic QEMU virt requires the separate mibox.test_restart=1 boot flag. The
hardware image contains no QEMU probe and does not add that flag.

The new toolbox exposes:

```sh
/bin/mibox reboot-android --check
/bin/mibox reboot-android --boot-id CURRENT_BOOT_ID
```

The second command asks PID1 to call normal Linux reboot(RESTART), without a
mode string. It does not request recovery, USB loader, slot switching, factory
reset, or an environment save. Acknowledgment means request acceptance only;
independent Android observations are mandatory for a successful return claim.

The exact stock kernel's NULL-command branch was rechecked against its
byte-preserving recovered ELF: it selects reason 0x01010101 before comparing
special mode strings. See
[kernel-normal-restart.json](../artifacts/software-return/2026-11-14/kernel-normal-restart.json).
This is static branch evidence, not proof of the subsequent bootloader path.

## Validation and separate candidate

- ARMv7 static release build passed for init, toolbox and QEMU-only probe.
- [QEMU normal restart](../artifacts/qemu-restart/normal-restart/result.json):
  UID2000 check passed; UID65534, stale ID, malformed and oversized requests
  were rejected; a stalled peer was closed; the listener remained usable.
  A UID2000 request then produced the kernel's Restarting system line and
  QEMU exited normally under -no-reboot, before host cleanup.
- [QEMU platform guard](../artifacts/qemu-restart/platform-guard/result.json):
  CHECK and RESTART were rejected without the test opt-in flag.
- [Actual candidate rootfs regression](../artifacts/qemu-restart/candidate-regression/result.json):
  all 10 PID1/console/reaper stages passed, including the USB board guard.

The new image is target/mibox-boot-candidate-restart/boot1-custom.NOT_READY.img,
8388608 bytes, SHA256:

`5608fa36caa28a7acf7a647b53db5d2775aaceb44730896f87da03f8ba6047fa`

It preserves the stock kernel, DTB, header cmdline and load addresses. Separate
[boot manifest](../artifacts/software-return/2026-11-14/boot-manifest.json),
[rootfs manifest](../artifacts/software-return/2026-11-14/rootfs-manifest.json)
and [independent inspection](../artifacts/software-return/2026-11-14/independent-inspection.json)
are retained. No private keys or QEMU probes are included. The previously
physical-tested candidate remains unchanged at SHA256
f05adbc3d79c8f41be7fef1145f6111f436d35921b7051722ae5195ae7624bba.

Reproduce from PowerShell and WSL:

```powershell
cargo build --release --bin mibox-init --bin mibox-userland --bin mibox-restart-probe
wsl -d Ubuntu-24.04 -- python3 /mnt/f/coding/otherPrj/mibox/scripts/build-qemu-initramfs.py --with-restart-probe
wsl -d Ubuntu-24.04 -- python3 /mnt/f/coding/otherPrj/mibox/scripts/test-restart-qemu.py
```

## Physical test procedure (completed once)

The owner first power cycled the old RAM boot back to Android, since
that PID1 had no privileged control route. Then verify normal ADB and Android
boot completion. A subsequent RAM-only test must explicitly pin the new image
and hash in the uploader, complete full readback, and independently verify the
new PID1/toolbox hashes before using its check or restart command. The current
loader script deliberately still pins the old baseline and will not upload this
new file by default.

For the return test, retain the custom boot ID and --check output before sending
the request. Observe USB disappearance/reappearance and require a different boot
ID, stock Android identity and sys.boot_completed=1. Treat timeout, disappearance
alone, an ADB recovery label, or request acknowledgment as insufficient evidence.
The uploader now offers explicit -Candidate Restart with a separate pinned hash,
limited to full UploadAndBoot. Baseline remains the default; -VerifyOnly validates
locally without USB access. The earlier old-only-uploader statement describes
the offline checkpoint. scripts/Test-MiboxSoftwareReturn.ps1 verifies executable
hashes and readiness, sends one request and checks the independent Android boot
against a retained pre-test baseline.

Keep owner power recovery available for future tests. Permanent installation
remains NOT READY.
## Host observer bounds follow-up (2026-11-15)

`Test-MiboxSoftwareReturn.ps1` now uses the shared retained-process runner for
every ADB call, with an eight-second execution deadline and bounded cleanup and
output EOF waits. Each call has a separate saved process record. Identity and
binary readback failures abort before the restart request. The overall return
timeout is checked between queries; a pending query can exceed it by its bounded
execution/cleanup/EOF allowance.

The normal restart request is still sent only once. A failed or disconnected
request is retained as such while independent Android polling continues.
Failed, timed-out or incomplete polls cannot pass even if their output contains
the expected identity. Original fingerprint, boot_completed=1 and a boot ID
different from both baseline and custom runtime remain required.

Offline fixtures passed 10/10, including failed preflight, request disconnect,
failed/incomplete return queries, stale boot ID and Android not yet completed.
The actual shared process suite passed 6/6, including a live descendant holding
output pipes after its root exits. Reproduce with
`powershell -NoProfile -File scripts/Test-SoftwareReturn.ps1` and
`powershell -NoProfile -File scripts/Test-RamBootProcess.ps1`.
Evidence: [return fixtures](../artifacts/software-return/host-tests-20261115-0648/results.json)
and [process fixtures](../artifacts/ram-boot/process-tests-20261115-064749-572/results.json).
No device operations occurred in this follow-up. This does not identify the
cause of the historical interrupted observer; its evidence remains unchanged.
