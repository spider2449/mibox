# Why the stock ADB menu returns to Deny after restart

The owner clarified that the setting in the box's menu changes back to Deny,
not merely that a network connection returns ECONNREFUSED. USB ADB subsequently
returned, so the current allow-state could be inspected without another reboot.

## Current device state

The attached box reported:

```
persist.sys.usb.config=adb
sys.usb.config=adb
sys.usb.state=adb
service.adb.tcp.port=5555
Settings.Global.adb_enabled=1
persist.sys.usb.netadb.config=0
```

The last property is a separate vendor TV-style flag; setting it blindly is not
a demonstrated fix for this box. Snapshots are under artifacts/adb-settings/2026-11-13/.
The boot ramdisk's persist.sys.usb.config=none is a default, not proof that
persisted settings are never loaded.

## Actual installed code

Copied /system/app/MiTVSettings-new.apk and extracted classes.dex. The box's own
/system/xbin/dexdump disassembled that dex. The initial APK-form invocation
could not create its /tmp extraction file; the unchanged dex was then copied to
/data/local/tmp and read directly. No APK was patched or installed.

The evidence excerpt and input hashes are in:

- artifacts/adb-settings/2026-11-13/policy-excerpt.txt
- artifacts/adb-settings/2026-11-13/source-hashes.json
- Full disassembly remains under phone-tools/runtime/2026-11-13/.

SystemInitService.startCheckInitSettings at dex code offset 0xea3d4 invokes
SettingsUtil.checkInitSettings (invoke at 0xea40a).
checkInitSettings at 0xe6398 performs these checks:

1. Read ro.debuggable and compare it with "1".
2. Read sys.cts.running as a boolean, default false.
3. If neither condition is true, branch on product type.
4. TV products call setADBEnable(0), which writes persist.sys.usb.netadb.config.
5. Other products, except product code 9, call setBoxADBStatus("0").

setBoxADBStatus at 0xe7c70 writes adb_enabled through Settings.Global on SDK >16
(Settings.Secure on older versions). Its enable path also sets the runtime TCP
port to 5555. getBoxADBStatus reads that same adb_enabled setting.

This directly identifies stock initialization code capable of clearing the
menu setting. The box reports ro.debuggable=0, and the owner's repeated restart
observation is consistent with this branch. A controlled reboot tracing the
exact product-code branch has NOT been performed. A persistent post-boot hook
was tested on 2026-11-14; both versions failed unattended USB recovery and were
rolled back to the verified original script. A third version using a bounded
SettingsProvider-only monitor subsequently captured the late reset and passed
unattended reboot recovery and stability checks. See
[installation and validation status](mibox-persistent-usb-adb.md).

## Development consequence

Do not diagnose every post-restart USB disappearance as a cable failure.
Re-enable ADB in the menu when needed and preserve the active session for reads.
Changing persist.sys.usb.config or adb_enabled once does not remove the explicit
startup reset policy. Disabling the whole initialization service would also skip
network/sound/other setup, so it is not an isolated fix.

The custom Rust system does not run this Android settings service, but that
does not by itself solve bootloader, console or recovery requirements. No stock
system package, boot image or security policy was modified by that investigation.
The later persistence attempt modifies only the existing post-boot script.

## Retained kernel log follow-up

Read-only crash collection succeeded after USB returned. /p/console-ramoops
contains a prior boot log and a CPU-frequency initialization warning/trace.
There is no captured USB-specific panic proving the ACM test caused a reboot;
dmesg-ramoops-0 and -1 are absent. The test's missing restore marker remains a
failure, and live USB switching stays disabled pending a conclusive explanation.
Original log: phone-tools/runtime/2026-11-13/crash.txt.
