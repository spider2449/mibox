# Updated health RAM boot and Android return

Owner authorized the updated RAM image and physical round trip. Preserve the
Baseline and Restart candidates. No flash, erase, environment save, USB ACM
switching, or persistent installation.

1. [x] Build separate health rootfs/image with stock kernel, DTB and owner public key.
2. [x] Run actual-rootfs QEMU regression and inspect layout and manifests.
3. [x] Add explicit Health candidate pins without changing existing defaults.
4. [x] Validate local candidate and orchestration guards before device transition.
5. [x] Full physical RAM upload/readback; verify new PID1/toolbox and health.
6. [x] Verify normal software return to completed stock Android; retain evidence.

Image: target/mibox-boot-candidate-health/boot1-custom.NOT_READY.img (8388608 bytes).
SHA256: 2788822cb79c3808ef6f4bb067fc4b57a033319c5fa0e93ecaec6874c8879bc3.
Manifests and QEMU 11/11 result: artifacts/health-ram-roundtrip/2026-11-14/.
Nine orchestration guard cases, 23 record validation cases and three Health
pin rejection cases passed. Baseline and Restart local checks passed unchanged.
Physical run: artifacts/ram-boot/20261114-191425-930/.

Result: PASS, 19:14:25 to 19:37:51 Asia/Taipei. Full RAM transfer took
1311.64 seconds. Custom boot ID: 71c18726-3f4f-4f23-826b-0357e5662fdb.
Health exit 0, boot identity matched, MemTotal 877072 KiB, MemFree 847924 KiB,
MemAvailable UNKNOWN. Both pulled executable hashes matched their pins.
Normal restart returned to completed Android with the original fingerprint
and boot ID 175120b6-cd0a-484c-bd05-a8fb038e8c1d.
Return evidence: artifacts/software-return/return-20261114-193635/.
No manual power recovery, flash/erase/environment save or persistent installation.
