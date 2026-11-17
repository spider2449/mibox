# Console Linux with SSH and persistent packages

The separate Console RAM image combines our custom PID1 with Alpine 3.22.8
ARMv7 userspace, BusyBox, apk and Dropbear. The stock kernel and DTB are retained.
No desktop is included. QEMU has verified SSH public-key login, interactive PTY,
DNS, HTTPS apk indexes, installing and running nano, and rejection without a key.
Physical SSH, PTY, DNS, HTTPS and installing/running nano and curl passed on
Linux 3.10.33. The persistent root has been provisioned, less installed there,
and package/database/configuration hashes recorded. Clean data unmount and
independent return to completed stock Android also passed. The second physical
RAM boot passed, and all five saved hashes matched: less, nano, curl, the apk
database and a configuration sentinel. The persistent interactive SSH terminal
also passed after reboot. **READY for this console/SSH/package workflow.**

Current physical boot ID: `e8946185-736d-41ca-8225-b14d012a74b1`.
The box was left running the persistent Linux console at `192.168.1.222`.
Available space after the second boot was 448160 KiB (about 438 MiB).

The QEMU virtual-disk test also passed: it created a persistent userspace,
installed curl there, cleanly unmounted it, booted a second VM using the same
disk, and verified both the installed program and configuration sentinel.

The image is pinned to SHA256
`4629deefd4e5e0f1902a54158ef01c7ad67156ef87946fb6d87c7070ba5da7c0`.
It uses 8343552 bytes of the fixed 8388608-byte RAM boot buffer. Earlier image
pins remain unchanged. SSH passwords and TCP forwarding are disabled.

## Use

From completed stock Android, with USB and wired Ethernet connected:

```powershell
powershell -NoProfile -File scripts/Start-MiboxConsole.ps1 -Boot -Connect
```

The launcher performs a full pinned RAM upload/readback if Android is running,
then activates the dedicated persistent userspace. If the Console candidate is
already running, omit `-Boot`. Host identity is taken from authenticated USB ADB
and checked strictly over SSH. No existing host known_hosts file is overwritten.
The owner private key remains at `%USERPROFILE%\.ssh\mibox-console` on the PC.
The launcher sets the system clock from the PC's UTC time before HTTPS package
operations; it does not depend on Android's time service running in the custom OS.

The release's `dropbearkey` writes even its public file as 0600. For an initial
boot the launcher may use a preliminary SSH connection solely to change that
public file to 0644. It then reads the key over authenticated USB and requires
an exact match before activating storage or running package commands. Private
server-key permissions remain unchanged. Earlier failed/incomplete validation
records are retained, including the initial USB public-key permission failure.

Within SSH:

```sh
apk update
apk add nano curl
nano /root/notes.txt
```

IPv4 is the previously owner-confirmed `192.168.1.222/24`, gateway
`192.168.1.1`. Physical startup uses no DHCP. Initial DNS servers are 1.1.1.1 and
9.9.9.9; the persistent `/etc/resolv.conf` can be changed for the LAN.

## Persistence and return

The launcher checks the data partition identity (179:11, 5168640 sectors) and
existing ext4 type. It creates only a dedicated `/mibox-console/rootfs` tree in
that filesystem; it does not format or resize the filesystem. Initial creation
requires at least the 256 MiB free-space floor. Android's app payload was
removed on 2026-11-17 with owner approval (plan S3); free space is now about
2.0 GiB. Android's `system`, `misc`, `property` and `ssh` remain until Phase C.

Free-space floor: 256 MiB (262144 KiB). On every start the helper writes
`/usr/local/sbin/apk` into the persistent tree, and the SSH shell puts it first
on PATH. It refuses `apk add|upgrade|fix|update` with exit code 75 when `/`
has less than the floor free; `del`, `cache clean`, `info` and other commands
pass through. `/sbin/apk` itself is unchanged and bypasses the guard. Below the
floor the console still starts and prints `MIBOX_DATA_BELOW_FLOOR`; the start
output always includes `MIBOX_DATA_FREE_KIB`.
The launcher installs GNU coreutils in the persistent root. BusyBox's `df`
follows an inaccessible outer mount path on this vendor kernel; GNU `df` correctly
reports space for `/` (the source column may be `-`).

PID1, USB ADB and the SSH transport stay in RAM. SSH login shells enter the
persistent Alpine tree, with explicit dev/devpts/proc/sys bind mounts. Packages,
the apk database, `/etc` and `/root` therefore live on disk. A fresh RAM boot
needs the launcher again to mount and activate this tree. Power-on still starts
Android; this change does not install Linux as the default boot target.

The original restart service deliberately refuses block filesystem mounts.
Close other SSH sessions and stop persistence before returning to Android:

```powershell
powershell -NoProfile -File scripts/Start-MiboxConsole.ps1 -Stop
powershell -NoProfile -File scripts/Test-MiboxSoftwareReturn.ps1 -Candidate Console -AndroidBaseline artifacts/ram-boot/<same-boot-run>/android-baseline.json
```

Stopping synchronizes and unmounts the data filesystem. Failure to unmount must
be resolved before requesting a restart. Do not use a generic BusyBox reboot
command as a substitute for the verified Android return control.

## Power off

The custom system has no verified power-off command. PID1 offers only a normal
restart and, in the `Loader` build, a restart into the USB loader. Power off by
making the system RAM-only, then removing power:

1. Close other SSH sessions, then stop persistence:
   `powershell -NoProfile -File scripts/Start-MiboxConsole.ps1 -Stop`.
   It must print `PERSISTENT_CONSOLE_STOPPED`. It syncs, unmounts the chroot
   bind mounts and unmounts `/mnt/mibox-data`. If it fails, do not remove power.
2. Confirm with `adb -s 248243005297 shell cat /proc/mounts` that only `rootfs`,
   `proc`, `sysfs`, `devtmpfs`, `devpts` and `functionfs` remain, with no `ext4`
   and no `/mnt/mibox-data`.
3. Remove power. Nothing is then writing to eMMC.

Optional, more conservative: after step 2, request a normal restart
(`/bin/mibox reboot-android --boot-id <current boot_id>`). With the host USB
attached the box then waits idle in C003, and power can be removed there.
The restart is refused while a block filesystem is mounted, so it also acts as a check of step 2.

Do not:
- use BusyBox `poweroff`, `halt` or `reboot`; they are not verified here.
- remove power while `/mnt/mibox-data` is mounted. That risks the persistent
  packages, apk database and configuration.

Next power-on: with the host USB attached the box stops in C003, so load the
system with `scripts/rescue-boot.ps1 -Action WaitAndBoot -Candidate FailSafe -Bulk`
and rerun the launcher to mount persistence. Without a host it boots Android.
For Android, use its own power-off (remote or menu). No host-side Android
power-off command has been verified.

Evidence of a clean stop before power-off (2026-11-16):
[launcher-20261116-221124](../artifacts/console-ssh/launcher-20261116-221124/result.json).

## Reproduce and evidence

Build `mibox-init` and `mibox-userland` with the repository's ARMv7 musl target.
Prepare the Alpine tree on Linux storage under WSL, with qemu-user-static installed:

```sh
sudo python3 scripts/prepare-console-alpine.py --destination /home/<user>/.cache/mibox-console-root-new
sudo python3 scripts/build-console-rootfs.py \
  --alpine-root /home/<user>/.cache/mibox-console-root-new \
  --ssh-public-key /mnt/c/Users/<user>/.ssh/mibox-console.pub \
  --adb-public-key /mnt/c/Users/<user>/.android/adbkey.pub \
  --output target/mibox-rootfs-console-new
python3 scripts/build-mibox-boot-candidate.py \
  --rootfs target/mibox-rootfs-console-new --output target/mibox-boot-candidate-console-new
```

New bytes require new pins and validation. Do not replace an existing validated
image or change its hashes to reuse earlier physical proof. Server host keys
are generated on the device in RAM; no private key is packaged in the image.

- [Pinned rootfs manifest](../artifacts/console-ssh/candidate/rootfs-manifest.json)
- [Pinned boot manifest](../artifacts/console-ssh/candidate/boot-manifest.json)
- [Generic ARM SSH/package tests](../artifacts/console-ssh/qemu/result.json)
- [PID1 regression](../artifacts/console-ssh/pid1-regression/result.json)
- [Virtual-disk persistence across two QEMU boots](../artifacts/console-ssh/qemu-persistence/result.json)
- [Physical SSH and package validation](../artifacts/console-ssh/device-20261115-083420/result.json)
- [Persistent package/configuration baseline](../artifacts/console-ssh/persistence-20261115-083834/result.json)
- [Independent Android return](../artifacts/software-return/return-20261115-083851/result.json)
- [Second full-readback RAM boot](../artifacts/ram-boot/20261115-084050-770/result.json)
- [Automatic persistent-console restoration](../artifacts/console-ssh/launcher-20261115-084050/result.json)
- [Physical cross-boot package/configuration verification](../artifacts/console-ssh/persistence-20261115-090313/result.json)

QEMU uses Debian 6.12.107 and a QEMU-only driver overlay; its success does not
establish compatibility with the physical Mi Box's Linux 3.10.33. Software
packages that require newer kernels still need their own compatibility checks.
