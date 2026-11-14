# Software boot and update path, 2026-11-14

Owner requirement: no disassembly of hardware or soldering. Continue software
investigation; UART is optional. No slot switch, boot environment write or
update invocation was performed for this analysis.

## Actual stock kernel configuration recovered

The expanded kernel contains IKCFG_ST at 7586368 and a complete gzip stream
from 7586376 to 7607335, followed by IKCFG_ED. Decompression validates gzip
integrity and yields 91528 bytes with 2765 config entries. Config SHA256:
bd2a94b6aa84afda30661c3a4b41f9759fcc6734ee32daf8335882ba6b43c918.
The expanded kernel SHA256 matches the earlier verified stock extraction.

| Setting | Actual value | Consequence |
| --- | --- | --- |
| CONFIG_IKCONFIG | y | Config is embedded in the binary |
| CONFIG_IKCONFIG_PROC | n | Explains the missing /proc/config.gz |
| CONFIG_KEXEC | n | The existing kernel cannot provide standard kexec boot |
| CONFIG_NAMESPACES | n | Do not plan isolated PID1 namespaces under this kernel |
| CONFIG_BLK_DEV_INITRD / CONFIG_RD_GZIP | y / y | Stock kernel has gzip initramfs support |
| CONFIG_DEVTMPFS / CONFIG_TMPFS | y / y | Required virtual filesystem support exists |
| CONFIG_MODULES / CONFIG_MODVERSIONS | y / n | Not sufficient by itself to build compatible modules |
| CONFIG_MODULE_SIG | n | Does not establish bootloader or OTA signature policy |

Absent subordinate config keys remain UNKNOWN in the JSON; they were not
invented as explicit disabled entries. CONFIG_USB_FUNCTIONFS=n coexists with
the live Android gadget using ffs: do not confuse the standalone FunctionFS
gadget option with the vendor Android gadget's function implementation.

Reproduce with scripts/extract-kernel-config.py against the existing expanded
stock kernel. Outputs: artifacts/platform/2026-11-14/kernel-config.json and
stock-kernel.config. No device configuration was changed.

## System selection traced in actual update library

libupdateservice.so SHA256:
d6cb8f1b0822f6c578b888cb92c85a6837e245587c69d96d604542357a497d45.
switchBootSystem starts at VA 0xb090. Audited Thumb PC-relative literals resolve
to ubootenv.var, bootsystem, the format %s.%s, ro.boot.system, and numeric 0/1.
The function gets current system from ro.boot.system, queries getUpdateStat,
and conditionally writes the opposite 0/1 to the constructed slot property
when update state equals 1. Later it sets persist.sys.ota.update=0 and
bootenv.var.otaupdate=1. This records code behavior, not authorization to call it.

Read-only runtime query returned ro.boot.system=1 and ubootenv.var.updatestat=1;
ubootenv.var.bootsystem was empty. Together with the observed system1 mount,
this provides stronger evidence of the active system than saved env alone.
An empty property is not evidence that setting it is safe or that fallback works.

Reproduce literal resolution with scripts/inspect-update-switch.py, which
refuses any library hash other than the audited binary. Output: update-switch.json.
Full objdump output is retained with the copied binaries under phone-tools.

## OTA verification is actually called

libupdate.so SHA256:
17a04a72075474fdbd55f22a64a03fa5409081d1d48580f51d21e8d0c97f0ac6.
The disassembly establishes this call sequence:

- update_ota at 0x61dc calls install_package at 0xb5e4 (call at 0x6226).
- install_package calls load_keys at 0xb614 and verify_file at 0xb650.
- verify_file's return is saved in r6. cbz at 0xb66c proceeds only on zero;
  the failure branch assigns result 2 and exits before try_updater.
- try_updater is called later at 0xb71a.

The binary includes /system/etc/security/keys and whole-file signature
verification diagnostics. A filename containing update_nosign.zip is therefore
not proof that this entry point accepts unsigned packages. No verifier was
patched and no update was attempted. Evidence excerpt:
artifacts/platform/2026-11-14/install-package-disassembly.txt.
OTA acceptance and bootloader image acceptance are separate questions.

## Current software route

Custom userspace already runs on the stock kernel, and PID1 integration passes
generic QEMU tests; see mibox-custom-userspace.md. Independent boot remains
gated on a verified image/loader path and an actual software recovery strategy.
The closed kexec and namespace options remove two misleading alternatives.
The stock kernel and DTB remain the preferred first boot inputs.

A fresh public-source search did not identify the exact g9f9cb70 vendor commit.
The official [MiCode repository](https://github.com/MiCode/MiBox_Kernel_OpenSource)
README currently lists MIBOX3(global)/once-o-oss, not this casablanca kernel.
That search is not proof that matching source is unavailable everywhere.
