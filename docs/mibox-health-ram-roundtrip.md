# Updated health RAM candidate

This candidate integrates the new read-only health snapshot into custom PID1
and the standalone toolbox, retaining the existing authenticated ADB and normal
restart control channel. It uses the verified stock kernel and DTB. Baseline
and Restart image hashes remain unchanged.

The new image is `target/mibox-boot-candidate-health/boot1-custom.NOT_READY.img`,
8388608 bytes, SHA256
`2788822cb79c3808ef6f4bb067fc4b57a033319c5fa0e93ecaec6874c8879bc3`.
Executable pins:

- `/init`: `8c2f9bcd4c5c26585062fbb5f44c7aeadbbe975217d28ab939f65173cb61cb6a`
- `/bin/mibox`: `2e4f1dfd8f28c0bf52323a9e65abf314e1e1705505414cc7cc25fcdf99128512`

The actual candidate rootfs passed 11/11 generic ARM QEMU stages, including
health output, console/reaper behavior and rejection of USB setup on the wrong
board. Nine orchestration guard cases, 23 record-validator cases, and three
Health image-pin rejection cases passed before the physical transition.
Build manifests retain conservative build-time status; physical outcome must
be established separately for this exact image.

Explicit selection preserves all previous defaults:

```powershell
powershell -NoProfile -File scripts/ram-boot.ps1 -Action Check -Candidate Health
powershell -NoProfile -File scripts/ram-boot.ps1 -Action RoundTrip -Candidate Health
```

Check is local only. RoundTrip requires completed stock Android, requests the
existing loader mode once, writes and reads back the complete RAM image,
validates SHA256 before bootm, pulls and hashes both custom executables, checks
health against the new guest boot identity, checks restart readiness and
independently verifies completed Android after a normal restart. No partition
write, erase or environment-save command is used. Android may make routine
persistent writes during normal operation/startup.

Build/QEMU evidence: `artifacts/health-ram-roundtrip/2026-11-14/`.
Physical run: `artifacts/ram-boot/20261114-191425-930/`.
## Physical result: PASS

The full round trip passed on 2026-11-14, 19:14:25 to 19:37:51 Asia/Taipei.
All 8388608 RAM bytes were compared and the complete SHA256 matched before
bootm. The transfer took 1311.64 seconds. Authenticated ADB returned under the
updated custom PID1; both pulled executables matched the pins above.

Custom boot ID: `71c18726-3f4f-4f23-826b-0357e5662fdb`.
The actual `/bin/mibox health` returned explicit exit 0 with matching boot ID,
PID1 init, rootfs root, uptime 9.76 seconds, MemTotal 877072 KiB and MemFree
847924 KiB. MemAvailable correctly remained UNKNOWN on Linux 3.10.33.

Restart readiness passed. One normal restart request returned the box to
Android; independent observations confirmed the original fingerprint,
`sys.boot_completed=1` and a different boot ID
`175120b6-cd0a-484c-bd05-a8fb038e8c1d`. No owner power cycle was needed.

- [Round-trip result](../artifacts/ram-boot/20261114-191425-930/result.json)
- [Physical health](../artifacts/ram-boot/20261114-191425-930/custom-health.json)
- [Independent Android return](../artifacts/software-return/return-20261114-193635/result.json)

The box is back on stock Android at this checkpoint. This is one successful
updated-candidate RAM boot and software return, not a persistent installation,
replacement-kernel validation, long-duration stability test or validation of
network/HDMI/audio. Generic QEMU alone did not establish this physical result.
