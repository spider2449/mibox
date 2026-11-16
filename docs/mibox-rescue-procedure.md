# MiBOX custom-system rescue procedure

Status: **READY** for the P0 scope in
[the rescue plan](plans/2026-11-15-custom-system-rescue.md) (2026-11-16).
RAM only. Nothing in this procedure writes a partition, the bootloader or the
U-Boot environment, and nothing depends on Android.

To shut the box down safely, see [power off](mibox-console-ssh.md#power-off).

## Preconditions

- The preboot USB window is installed (`preboot` contains `update 10000;`,
  read-back hash `6142e34f…`, see [independent rescue](mibox-independent-rescue.md)).
  Every restart, warm or cold, passes the C003 USB loader while a host is attached.
- The host has the WinUSB binding for `USB\VID_1B8E&PID_C003` and the pinned
  candidate `target/mibox-boot-candidate-console-failsafe/boot1-custom.NOT_READY.img`
  (SHA256 `f5e9cd6b…`).
- Manual power recovery is within reach (outlet or remote).
- Backups verify: `powershell -NoProfile -File scripts/Verify-MiboxBackups.ps1`
  must print `LOCAL_BACKUP_INTEGRITY_PASS`.

Local-only check (no USB access):

```powershell
powershell -NoProfile -File scripts/rescue-boot.ps1 -Action Check -Candidate FailSafe
```

## Procedure

### 1. Bring the box to C003

Pick whichever applies:

| Box state | Action |
| --- | --- |
| Custom system running, ADB reachable | `adb -s 248243005297 shell /bin/mibox reboot-android --check`, then `--boot-id <current /proc/sys/kernel/random/boot_id>`. This is a normal Linux restart (no mode string). |
| Custom system crashed early (PID1 panic, USB setup failure or hang) | Nothing. The PID1 fail-safe restarts by itself, within 60 s plus at most 15 s of sync. |
| Kernel panic | Nothing. `kernel.panic=20` restarts it. |
| Hung with no ADB, or the transfer stopped | Power cycle by hand with the USB cable attached. |
| Android running | Power cycle with the USB cable attached (cold entry passes C003). |

### 2. Load and boot the pinned rescue image

```powershell
powershell -NoProfile -File scripts/rescue-boot.ps1 -Action WaitAndBoot -Candidate FailSafe -Bulk
```

Success prints `RAM_RESCUE_LOADED`, and the evidence goes in `artifacts/rescue-boot/<timestamp>/`.
Without `-Bulk` the same image goes over the EP0 control channel with a full
8 MiB readback (~22 min). Use that only if bulk fails.

## Stages, limits and evidence

| Stage | Limit | Checks | Evidence file |
| --- | --- | --- | --- |
| Local check | 30 s | image size 8 MiB, pinned SHA256 | `local-check.json`, `provenance.json` (script hashes) |
| Wait for C003 | `-WaitSeconds` 120 s | exactly one C003 node, driver OK | `usb-events.jsonl` |
| Identify loader | 20 s | VID:PID `1B8E:C003`, identify `00-08-00-10` | `loader-identify.json` |
| Ambiguity guard | 8 s | target ADB must **not** be present alongside C003 | `pre-upload-adb.json` |
| Upload and boot | `-TransferTimeoutSeconds` 3600 s; 10 s per control request | bulk: device `crc32` of all 8 MiB equals host value, plus 129 sampled EP0 reads; control: full readback SHA256 | `upload-and-boot.json` |
| Custom runtime | 120 s (210 s wrapper) | `ID=mibox-custom`, PID1 identity, new boot ID | `custom-observer.json` |
| Executable hashes | 20 s per pull | `/init` = `a24de13a…`, `/bin/mibox` = `e275d1d0…` | `init.elf`, `mibox.elf` |

`result.json` records every stage. `FlashCommandSent`, `EnvironmentWriteSent`
and `LoaderRequestSent` stay `false`.

Typical timing with `-Bulk`: about 8 s upload, about 23 s from loader to verified custom system.

## Failure handling

- **No C003 within the wait:** nothing has been sent. Power cycle with USB attached, then run step 2 again.
- **Identity mismatch, several C003 nodes, or ADB present together with C003:** the script stops before
  uploading. Do not override. Find the cause first.
- **Transfer timeout or loader stops responding:** no retry and no loader reset.
  Power cycle by hand, then run step 2 again. This is the normal recovery path, not a test failure.
- **Bulk fails twice in a row:** run step 2 without `-Bulk` (control channel, full readback).
- **Hash or runtime check fails after boot:** the box is running something unverified. Power cycle and repeat.
  If it repeats, stop and go back to QEMU and static analysis.
- **Stop all physical testing** if the loader shows unexpected prompts, a C003 session deviates from the
  recorded behaviour, or continuing would need any unverified command (plan red lines).

## Status of the scope

| Case | Status | Evidence |
| --- | --- | --- |
| Manual loop: custom ADB → PID1 restart → C003 → pinned image → new custom ADB | **PASS** (full readback) | `artifacts/rescue-boot/20261115-175944-393/` |
| C003 → pinned image → verified custom system, bulk upload | **PASS** | `artifacts/rescue-boot/20261116-214805-314/`, `20261116-215601-279/` |
| Auto return: PID1 panic | **PASS**, 12.4 s | `artifacts/fail-safe/20261116-200046-745-panic/` |
| Auto return: USB setup failure | **PASS**, 12.4 s | `artifacts/fail-safe/20261116-202305-984-usb/` |
| Auto return: USB setup hang (60 s deadline) | **PASS**, 72.4 s | `artifacts/fail-safe/20261116-204511-921-hang/` |
| Auto return: kernel panic (supplementary) | **PASS**, 35.6 s | `artifacts/fail-safe/20261116-215504-379-kpanic/` |
| Cold entry with host attached | **PASS** (two cold starts) | `artifacts/console-ssh/launcher-20261115-212455` |
| Cold start without host continues to existing boot | **PASS** (one owner observation, no host record) | plan status table |
| `usb_burner_reboot` request from the custom system (`Loader` candidate) | **PASS** for the request path: C003 after 3.5 s, stale ID refused; QEMU shows the kernel restarts with command `usb_burner_reboot` | `artifacts/loader-restart/20261116-220632-376/`, `artifacts/qemu-restart/loader-20261116/` |
| Same request with the preboot window removed (proves the 0x09090909 branch alone) | **NOT_TESTED**; needs an env write to remove the window, owner decision | — |

Fault images were RAM-only (`MIBOX_FAULT` builds) and none were flashed. Each fault case was
run with `scripts/Test-MiboxFailSafe.ps1 -Fault <Panic|Usb|Hang|KPanic> [-Bulk]`.

## Limits of this guarantee

- Everything depends on the preboot window in the env. If the env is lost or reset, warm restarts no longer
  pass C003. The `Loader` candidate's `usb_burner_reboot` request is then the fallback; its loader
  branch is proven from Android on the same kernel, but not yet from the custom system without the window.
- It does not cover a kernel or PID1 that cannot run at all, a damaged bootloader, or failed storage.
- Without a host, the window expires and the existing boot partition starts (Android today). Once a custom
  system is written to the boot partition, a crashing image will restart in a loop with no host attached. Revisit this
  before any persistent installation.
- A successful RAM reload does not prove that a partition can be flashed back.
- The bulk path checks the uploaded data with the loader's `crc32` plus 129 sampled blocks, not a byte-for-byte readback.

## Fallback: restart into the USB loader by reason

For use if the preboot window is ever lost. The `Loader` candidate
(`9c454362…`, init `9b633cde…`, `/bin/mibox` `d182d76d…`) is the FailSafe image
built with the cargo feature `loader-restart`. Its PID1 also accepts
`LOADER <current boot_id>`, under the same root-PID1, custom-OS, RAM-only-mounts and
stock-kernel checks as the normal restart. It then calls
`reboot(LINUX_REBOOT_CMD_RESTART2, "usb_burner_reboot")`; the stock kernel maps
that to reason 0x09090909 (`usb_burning`) ([loader branches](mibox-loader-entry-branches.md)).
Default builds, including the pinned FailSafe image, reject `LOADER`.

```powershell
powershell -NoProfile -File scripts/rescue-boot.ps1 -Action WaitAndBoot -Candidate Loader -Bulk
adb -s 248243005297 shell /bin/mibox reboot-loader --boot-id <current boot_id>
# or the evidence-keeping test: scripts/Test-MiboxLoaderRestart.ps1
```

Limits:
- Like RESTART, it is refused while any non-RAM filesystem is mounted. Unmount persistent data first.
- This adbd returns exit code 0 even when the command fails, so check the output
  (`boot ID does not match current boot` means refused). The accept reply is usually lost to the restart.
- With the window installed, a normal restart reaches C003 in about 4 s and this request in 3.5 s, so the
  physical run proves the request path only. The bootloader branch is proven statically and from Android.
