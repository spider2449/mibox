# Restoration readiness, 2026-11-14

Permanent installation: **NOT READY**. A successful restart from a RAM-only
custom boot leaves the existing Android boot images available; it does not
demonstrate recovery after replacing one of those images.

## Local backup verification

Run `powershell -NoProfile -File scripts/Verify-MiboxBackups.ps1` from the repo.
The tool reads local images only and compares their lengths and SHA256 with
the retained device-verified manifests. It also checks contiguous system chunk
coverage. Report: [backup-verification.json](../artifacts/restoration/2026-11-14/backup-verification.json).
This is an integrity check against historical evidence, not a fresh device read.

The intended inventory is seven named partitions, two assembled system images
and sixteen system chunks. system1 includes the installed V3 USB ADB hook;
it is a recovery snapshot of that state rather than pristine factory firmware.
The incomplete hardware boot0 read and the abandoned zero-byte system image
are excluded. Userdata and complete eMMC hardware boot areas are not backed up.

## Reviewable restoration sequence and gates

Host-only rehearsal now passes 11/11 cases using the pinned complete 8 MiB
stock boot1 backup and disposable regular-file targets. It checks copy/flush/
readback, wrong identity, short and oversized target, wrong source hash,
source/target alias, short source, target outside sandbox, interruption,
readback corruption and a complete retry after failure. Rejections before
copy preserve target bytes; injected failures after writing leave a changed
target and never return a restoration-success result.

Reproduce:

```powershell
wsl -d Ubuntu-24.04 -- python3 /mnt/f/coding/otherPrj/mibox/scripts/test-restoration-host.py
```

[Machine-readable rehearsal results](../artifacts/restoration/2026-11-14/host-rehearsal.json).
The script creates and removes its own temporary directory. It has no CLI for
selecting a destination and no device access. Its synthetic identity check
does not implement physical partition identity verification, and host fsync
does not establish eMMC write durability. This model is not installed in the
RAM image or connected to PID1. The gates below remain necessary.

1. Before selecting any persistent target, capture its current device identity,
   major/minor mapping, exact byte length, mount state and boot-selection role.
   The saved env suggests boot1, but dynamic preboot behavior remains UNKNOWN.
2. Demonstrate that an independent RAM rescue path remains reachable when that
   target cannot boot. The existing Android `adb reboot usb_burner_reboot`
   entry depends on a working Android session; that dependency has not been
   eliminated. No claim of recovery from a broken boot partition is justified.
3. Provide a narrowly scoped restoration implementation in the rescue runtime.
   Current PID1 exposes CHECK and normal RESTART only. Arbitrary partition
   restore, target identity checks and durable write/readback are unimplemented
   and untested. Do not use the loader's RAM control writes as flash commands.
4. Validate the implementation against disposable host files, including wrong
   size/hash/target rejection and interrupted-transfer behavior, before any
   separately scoped physical restoration experiment.
5. A physical restoration result must include complete post-write readback
   matching the selected backup, followed by an independent Android boot ID,
   original fingerprint and boot_completed=1. A write acknowledgment or reset
   alone cannot close this gate.

No step above has been executed as a partition restoration. No flash command
is supplied because the independent rescue entry and target mapping are not
yet established. Bootloader, env, reserved and hardware boot areas remain
outside a prospective single-boot-image experiment.

Stock recovery is also unproven as a rescue transport: its extracted init
configuration does not establish automatic ADB access. Its restore_system.sh
deletes and repopulates system, and does not restore boot images or system1.
See [readiness evidence](mibox-boot-readiness-2026-11-14.md),
[backup scope](mibox-system-backups.md) and
[successful RAM return](mibox-software-return.md).

This follow-up used no device connection, reboot or partition write.

## Independent entry follow-up

The exact CRC-verified saved environment contains a pre-Android remote path:
`preboot` invokes `update_key`; that command tests `monitor_bt_cmdline` and
`irdetect`, and either true condition invokes `run recovery`. The required
remote keys, timing and actual cold-start behavior remain UNKNOWN. This is a
candidate recovery entry, not a demonstrated entry into the C003 USB loader.

`storeboot` also contains `bootm;run recovery`. That continuation requires
bootm to return; there is no evidence here that it handles a kernel or PID1
hang after execution has transferred. Do not test it by damaging a partition.

The saved `storeargs` includes `saveenv`, and `preboot` has a conditional
`defenv`/`saveenv` path. Thus a host test issuing no persistent-write command
does not prove the stock bootloader itself makes no persistent writes during
startup. No such command was executed in this investigation.

The pinned 2 MiB named bootloader backup contains only one matching rescue
ASCII run (`recovery`, file offset 18704) in the bounded keyword inventory.
No gzip, xz, LZ4 frame, uImage, FDT or ELF magic was found by this scan. These
negative results neither establish the image layout nor rule out another
encoding or a boot ROM rescue entry. No execution base was assumed.

Reproduce with `scripts/inspect-rescue-entry.py` under WSL Python3.
[Exact commands, entry offsets and scan results](../artifacts/restoration/2026-11-14/rescue-entry.json)
are retained. Testing a remote cold-start entry requires owner participation;
recovery availability and its usable console remain unverified.

Later [UCL bootloader extraction](mibox-bootloader-ucl.md) supersedes the
negative compressed-input string inventory above. The exact expanded loader
now provides command registrations, an IR assembled-value comparison and
evidence that the BT accepted-response path calls the saveenv backend.
Physical button mapping and independent USB rescue entry remain UNKNOWN.

Owner follow-up: the box has no SD slot. The stage-one SD/MMC-style external
load reader therefore does not provide a directly accessible card-based
rescue experiment within the no-disassembly constraint. A USB card reader
cannot be assumed equivalent. Further practical entry investigation must
focus on the existing USB device connector and remote-triggered recovery;
neither has yet demonstrated an Android-independent usable rescue console.

Later owner-operated HOME+MENU testing did not demonstrate recovery entry.
The owner reports that the touch remote cannot invoke this combination;
ordinary IR key events do not establish chord support. A new Android boot
completed afterward with retained identity evidence. See
[cold-entry attempt and return checkpoint](mibox-cold-recovery-attempt.md).
This remote method does not close the independent rescue gate.
