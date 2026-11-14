# MiBOX1S Linux bring-up

## Goal

Develop a custom Linux system for MDZ-06-AA / casablanca. Start with a minimal
kernel and initramfs reaching a console. Replace internal Android only after a
working boot path and a verified recovery procedure exist.

## Confirmed on the attached device

- USB serial: 248243005297; product: casablanca_icntv; model: MiBOX1S.
- Amlogic Meson6, dual Cortex-A9 ARMv7, NEON/VFPv3.
- Android 4.4.2, build 7.2.20.2876, Linux 3.10.33.
- MemTotal: 877072 KiB; eMMC: 3866624 KiB.
- Shell UID 2000, SELinux Enforcing; adb root rejected by production adbd.
- bootloader, env, recovery, boot/boot1, system/system1, cache and data exist.
- Lock/verified-boot properties are empty: lock state is UNKNOWN.
- /proc/config.gz absent; shell cannot read /proc/cmdline or init scripts.

## Work sequence

Updated after inspecting the owner's `amazing-a32-os` reference: prioritize a
stock Mi Box kernel plus custom Rust initramfs before a new kernel port. See
`docs/amazing-a32-reference.md` for reusable components and board-specific work.
The original kernel-source investigation below remains the later kernel track.

- [x] Inspect A32 build/userspace/boot tooling and record a reuse map.
- [x] Build and execute a minimal static ARMv7 read-only probe under stock Android.
  Rust 1.99.0 static-musl binary completed on USB serial 248243005297, UID 2000,
  Linux 3.10.33; output includes MIBOX_PROBE_OK. Evidence: artifacts/probe/2026-11-13/.
- [x] Develop and cross-build a minimal Mi Box PID1 candidate locally.
  QEMU PID1/console/reaper test initially passed 8/8 stages; custom toolbox
  integration on 2026-11-14 passed 10/10 in normal and USB fallback cases.
  A local NOT-READY stock-kernel/custom-rootfs boot candidate was later packaged
  and independently parsed on 2026-11-14, then physically RAM-booted with
  custom PID1 and authenticated USB ADB. See docs/mibox-ram-boot-success.md.
  Long-duration watchdog behavior and persistent installation remain unverified.
- [x] Run custom static userspace in an unprivileged chroot on the actual box.
  File I/O, rootfs identity/isolation and child execution passed; no independent
  boot or hardware PID1 claim. Embedded stock kernel config also recovered.
- [x] Investigate the owner's report that ADB menu resets to Deny after restart.
  Installed Settings APK initialization can clear adb_enabled on production
  boxes. V3 startup monitoring captured a late reset and automatically restored
  USB ADB across a controlled reboot. See docs/mibox-persistent-usb-adb.md.

1. [x] Inventory CPU, RAM, storage, permissions and partition names.
2. [x] Add repeatable read-only collection and preserve accessible files locally.
3. [x] Identify upstream Meson6 source as a reference, not a working board port.
4. [x] Obtain matching stock boot/recovery/bootloader images and hashes.
   Completed after USB reconnect: seven bounded raw partition backups saved in
   phone-tools/backup/2026-11-13; host/device SHA-256 matched for all seven.
   boot1 prefix matches installed script's boot SHA-1; recovery prefix also
   matches. boot has a different prefix. See docs/mibox-stock-images.md.
   Temporary root command execution uses the existing pppoe_wrapper daemon;
   no permanent su installation. Earlier acquisition research is recorded in
   docs/mibox-ota-investigation.md and docs/mibox-root-access.md.
5. [ ] Establish recovery procedure and inspect boot-image headers offline.
   Header/section analysis complete; recovery procedure remains untested.
6. [ ] Identify UART pins and voltage from board evidence; capture boot log.
7. [ ] Determine bootloader commands, signature checks and RAM boot support.
   Saved env CRC validated for 32768 bytes; default storeboot reads boot1.
   The exact candidate passed full RAM readback and bootm execution through
   C003 WinUSB. Dynamic preboot selection and general signature policy remain
   unverified; this item remains open for those questions.
8. [ ] Select kernel: matching vendor BSP or upstream with a casablanca port.
9. [x] Create ARMv7 Rust initramfs; validate PID1 userspace in QEMU.
   See docs/mibox-init-qemu.md and artifacts/qemu/result.json. This does not
   emulate the Meson6 board or the stock kernel.
10. [x] Boot without persistent writes where the bootloader supports it.
   Verified 8 MiB RAM image, custom PID1/userspace and FunctionFS ADB on the
   physical box. See docs/mibox-ram-boot-success.md.
   A newer candidate also passed normal software restart back to Android;
   see docs/mibox-software-return.md. Permanent-install restoration remains
   a separate untested gate.
11. [ ] Bring up storage, USB, networking, HDMI and audio individually.
   USB ACM packets exchanged through Windows COM6, but a later test showed
   reset/incomplete restore evidence. Live switching is disabled pending
   retained-log analysis; see docs/mibox-usb-acm-evidence.md. Optional USB init
   support compiled; QEMU UART fallback passed all 8 stages. FunctionFS ADB
   subsequently passed on the physical custom boot; ACM remains unverified.
12. [ ] Back up original partitions and test recovery before internal install.

2026-11-14 follow-up: recovery tail, restoration scripts and runtime boot
alternatives analyzed. See docs/mibox-boot-readiness-2026-11-14.md. Hardware
boot was NOT READY at that checkpoint. The later exact-candidate temporary
RAM boot passed; no custom boot partition writes have been made. Persistent
installation remains NOT READY pending a tested restoration procedure.

## Current constraints

Do not infer fastboot, U-Boot commands, image offsets, load addresses, UART voltage
or DT compatibility from another Amlogic box. Do not use S905/S912 images.
Root alone does not demonstrate an unlocked boot path. A second boot/system slot
does not establish a safe fallback or modern Android A/B behavior.

## Source leads checked 2026-11-13

- https://github.com/MiCode/MiBox_Kernel_OpenSource
  README lists MIBOX3(global), once-o-oss; no matching casablanca source identified.
- https://raw.githubusercontent.com/torvalds/linux/v6.12/arch/arm/boot/dts/amlogic/meson6.dtsi
  Confirms upstream Meson6/Cortex-A9 SoC description; not a casablanca board DTS.
- https://www.linux-meson.com/hardware.html
  Meson6/AML8726MX support reference; SoC support is not complete board support.

## Local tools

Run `powershell -File scripts/Collect-MiboxInfo.ps1` with USB connected.
Results go to a new timestamped directory under artifacts/device-info/.
This is an inventory, NOT a firmware backup.
