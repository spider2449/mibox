# Physical custom userspace RAM boot, 2026-11-14

Result: PASS for temporary RAM boot on MiBOX1S MDZ-06-AA. The box is running
the original 3.10.33 kernel and DTB with our custom Rust PID1 and userspace.
This is not a newly built kernel, a full Linux distribution or a persistent install.
No boot, recovery, system or bootloader partition was written during this test.

## Transfer and boot

After owner power recovery, Android boot ID was
7cdd0201-07f5-43be-bd8e-ba9576fe3416. The normal ADB connection and
boot_completed=1 were verified. `adb reboot usb_burner_reboot` entered C003.

`scripts/Test-MiboxLoaderRam.ps1 -Action UploadAndBoot` used only the verified
64-byte control read/write channel at 0x82000000..0x82800000. All 8388608 bytes
were written and read back, with byte comparisons and complete SHA256:

`f05adbc3d79c8f41be7fef1145f6111f436d35921b7051722ae5195ae7624bba`

Only after that check passed did the same session send the fixed command
`bootm 0x82000000` using vendor OUT request 0x30, index 1, 64 zero-padded bytes.
The control transfer completed. USB loader disappeared, and USB ADB returned.
The earlier 512-byte reset command and bulk-read diagnostic failed; this
success does not establish those paths. Bulk image actions remain disabled.

Transfer evidence: artifacts/usb-loader-protocol/2026-11-14/
upload-and-boot.json and upload-and-boot-progress.txt.

## Independent device evidence

Primary evidence directory:
`artifacts/usb-loader-protocol/ram-boot-20261114-095452/`.

- New boot ID: dd2afb3c-091b-4e84-bfde-d468ef3045b1.
- `/etc/os-release`: ID=mibox-custom, VERSION_ID=0.1.0.
- `/bin/mibox info`: kernel=3.10.33, uid=2000, euid=2000.
- PID1 status: init, Pid=1, PPid=0, sleeping.
- Pulled `/init` SHA256 matches the built manifest:
  65e0e3be7b92a087ec2e2978ad4bd5e1539cff93400c9abee177ceea77788996.
- Pulled `/bin/mibox` SHA256 matches the built manifest:
  27416a3aa406b7f760ebccd2070d56298f30efef75aa658e1beee583571f51d0.
- The custom child probe returned 17, and a shell write followed by the custom
  tool's read returned MIBOX_RAM_BOOT_FILE_IO_OK from `/tmp`.
- Mounts contain only rootfs, proc, sysfs, devtmpfs, devpts and ADB FunctionFS;
  no eMMC block filesystem is mounted.
- At the end of checks uptime was 137.79 seconds; boot ID remained unchanged.

`verification.json` records nine passing checks. This is actual device evidence,
separate from the earlier QEMU runs and Android chroot tests.

ADB advertises the `recovery` state because the image includes the stock
recovery adbd. That label alone does not identify the running OS; the marker,
custom executable output, new boot ID and matching files establish this result.
The first observer accepted only `device`, so it timed out while this transport
was already usable. Its retained directory ram-boot-20261114-095253 is
superseded by the corrected observer and primary evidence above.

## Current use and limits

The custom system remains running. For example:

```powershell
& .\phone-tools\platform-tools\adb.exe -s 248243005297 shell /bin/mibox info
& .\phone-tools\platform-tools\adb.exe -s 248243005297 shell /bin/mibox ls /
```

Power cycling returns to the existing Android installation; that fallback was
demonstrated before this boot. The custom system is not installed persistently.
The minimal rootfs does not include general commands such as uname, id or
getprop; use `/bin/mibox info` for its kernel/UID report. The older recovery shell
may return ADB exit code 0 even when a command is missing, so evidence checks
must inspect output, not only the host exit code.

Display, network, storage drivers, long-duration stability, software-only return
from this new userspace and persistent installation remain unverified. The
previous build manifests retain their original NOT_READY status as historical
build-time records; this document and runtime evidence supersede the physical
RAM boot / FunctionFS uncertainty for this exact candidate only.
