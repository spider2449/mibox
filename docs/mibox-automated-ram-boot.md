# Automated RAM boot and Android return

`scripts/ram-boot.ps1` follows the owner's A32 workflow pattern: initiate the
bootloader transition from the host, wait for its transport, transfer the RAM
image, and independently observe the new runtime. It uses the Mi Box's exact
verified USB loader protocol rather than importing A32 fastboot commands,
addresses or board configuration.

```powershell
# Local pinned-image checks only; no ADB or USB device access.
powershell -NoProfile -File scripts/ram-boot.ps1 -Action Check

# Android -> loader -> verified custom RAM boot; leave custom userspace running.
powershell -NoProfile -File scripts/ram-boot.ps1 -Action Boot

# Same boot, then request and independently verify software return to Android.
powershell -NoProfile -File scripts/ram-boot.ps1 -Action RoundTrip
```

The default action is Check. Boot and RoundTrip require a completed stock
Android baseline on serial 248243005297 before issuing one
`adb reboot usb_burner_reboot`. The script waits for exactly one healthy C003
device, then invokes the existing restricted control-channel uploader with
the Restart candidate. All 8388608 RAM bytes must compare, and the full RAM
SHA256 must match the previously physical-tested image:

`5608fa36caa28a7acf7a647b53db5d2775aaceb44730896f87da03f8ba6047fa`

After bootm, independent ADB observations must show custom OS identity, init,
a changed boot ID, exact /init and /bin/mibox hashes, and the PID1 restart
interface reporting readiness. RoundTrip delegates to the existing return
verifier, requiring its structured physical-return result: another Android
boot ID, original fingerprint and boot_completed=1. Request acknowledgment,
USB disappearance or an ADB recovery label alone cannot establish success.

Evidence is retained under a new `artifacts/ram-boot/<timestamp>/` directory.
Subprocess output/error, deadlines, current stage, and baselines are recorded.
Pulled executables stay ignored. Failed mode requests, transfers or readiness
checks stop the script; it sends no automatic retry, loader reset, flash,
erase or environment-save command. No remote-key interaction is required for
this normal Android-based workflow. Unexpected failures may still require
owner recovery; automation is not a guarantee against hardware/transport loss.

## Validation

The real pinned-image Check passed without device access. Five isolated
orchestrator guard cases passed: valid local record, wrong hash, wrong size,
claimed USB access and checker failure. Rejection cases requested RoundTrip
but stopped before device access or a loader request. The test creates its own
fixture workspace under target and cannot invoke real ADB/USB.

[Guard results](../artifacts/ram-boot/guard-tests.json).
Run `powershell -NoProfile -File scripts/Test-RamBootGuards.ps1` to repeat them.

## Physical round trip: PASS

The 2026-11-14 14:29:58–14:53:19 Asia/Taipei run passed all stages. No owner
remote or power action was requested during this run:

- Baseline Android boot ID: 6d4f3f97-d576-4600-9c99-9d2814e07629.
- Full 8388608-byte RAM readback matched the pinned SHA256 above, using the
  control channel with BulkMode=false; bootm transfer completed.
- New custom boot ID: 695ecb4b-717c-4b1b-8e1c-0faaeee26c2b. The observer,
  pulled executable hashes and PID1 readiness interface passed.
- Software return produced Android boot ID
  ecdad7fb-31d0-4e02-adb5-863bdf0529d5, original fingerprint and
  boot_completed=1. The final live checkpoint also returned boot_completed=1.

[Orchestrator result](../artifacts/ram-boot/20261114-142958-301/result.json),
[full RAM verification](../artifacts/ram-boot/20261114-142958-301/upload-and-boot.json),
[custom observations](../artifacts/ram-boot/20261114-142958-301/custom-observer.json)
and [independent Android return](../artifacts/software-return/return-20261114-145204/result.json)
are retained. Script hashes for the running version are recorded in
orchestrator-provenance.json beside the result.

The first wrapper used a 1200-second transfer deadline, shorter than this
observed control-channel transfer. Before it expired, the host wrapper was
briefly paused through the PowerShell debugger to change only its local wait
deadline to 3600 seconds, then detached. The uploader child and USB session
continued; no device command or transfer was restarted. The result records
HostDeadlineAdjustedDuringTransfer=true. That host intervention is a limit
of this first orchestration test, not owner/device intervention. The persisted
script now defaults to 3600 seconds via TransferTimeoutSeconds and passed a
fresh device-free Check; the default change did not trigger another physical
boot. A later fully unattended repeat of this revised default is not claimed.

Earlier manually orchestrated RAM boot and software return results remain
documented separately. Permanent
installation and recovery from broken Android are separate, unverified gates;
they are not prerequisites for repeating the already proven RAM-only workflow.
