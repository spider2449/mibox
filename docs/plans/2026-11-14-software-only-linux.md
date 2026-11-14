# Software-only custom Linux route

Owner constraint: no hardware modifications, disassembly or soldering.
UART is optional and is not a prerequisite for this project.

1. [x] Inventory existing software update tools without executing them.
2. [x] Copy runupdate, updateservice, updatetest and update libraries for offline analysis.
3. [ ] Trace update package verification, partition selection and boot selection.
   OTA signature gate and switchBootSystem are traced; raw image acceptance
   and the full partition copy/recovery procedure remain unverified.
4. [x] Develop custom ARMv7 userspace under the existing stock kernel, initially
   confined to a dedicated /data directory. A chroot test is not an independent boot.
5. [ ] Establish a software-only recovery/return path before any boot image write.
6. [ ] Test independent boot only after image acceptance and return-path gates pass.

Observed tools include /system/bin/runupdate, updateservice and updatetest.
libupdateservice.so exports switchBootSystem and refers to boot environment
and update state; libupdate.so contains verify_file and RSA_verify symbols.
These are leads, not proof of a usable loader or accepted custom image.
No update command, unlock command or boot environment write is authorized by
mere tool discovery; continue within the owner's existing custom-OS scope with
reviewable results and a verified recovery strategy before irreversible writes.

Local copies: phone-tools/runtime/2026-11-14/boot-tools/.
Strings: artifacts/platform/2026-11-14/*-strings.txt.

Offline ARM disassembly confirms switchBootSystem calls getUpdateStat,
property_get and conditionally property_set. Exact property semantics and
safe fallback still require tracing; do not invoke the service to test them.
Binary hashes are recorded in software-update-manifest.json.

The unintended diagnostic reboot was followed by automatic ADB recovery.
Current-boot hook completion, protection checks and 20-second stability passed:
artifacts/adb-persistence/verification-20261114-070111/result.json.
This validator did not issue a reboot (RebootRequested=false); the independently
observed changed boot ID was 4eda0d4f-8c10-4191-bd80-dc615a9991e4.

Follow-up: custom userspace physically tested with unprivileged chroot children;
PID1 toolbox integration passes 10/10 QEMU stages. Embedded stock IKCONFIG
recovered, confirming CONFIG_KEXEC=n and CONFIG_NAMESPACES=n. See
docs/mibox-software-boot-analysis.md for exact binary control-flow evidence.

Both 512 MiB system partitions now have complete host/device-hash-verified
snapshots. Hardware boot0 read was incomplete and is explicitly excluded from
restore claims. Stock recovery adbd/sh are static ARM executables, retained as
offline USB console candidates. Saved env's usb_burning=update 1000 was traced,
not invoked. Independent boot gates remain open; no custom image was flashed.

Stock recovery adbd plus custom init/toolbox now pass isolated QEMU ADB shell
tests, including cached public-key authentication and bad-signature rejection.
Baseline, authenticated and missing-flag guard modes each pass 11/11. No physical
USB switch or authenticated control channel on a new MiBOX boot is claimed.

Later physical milestone: the full 8 MiB candidate was uploaded into RAM,
read back and SHA256-verified, then booted via a fixed 64-byte TPL bootm command.
Custom Rust PID1/userspace and physical USB ADB passed nine retained checks.
See docs/mibox-ram-boot-success.md. The box remains in this temporary custom
system; no persistent installation or newly compiled kernel is claimed.
