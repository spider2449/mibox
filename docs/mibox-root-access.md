# MiBOX1S temporary root command execution

## Observed result (2026-11-13)

On USB serial 248243005297, the fixed identity check returned:

```
ACK: Ok(8)
uid=0(root) gid=1000(system) groups=3003(inet) context=u:r:init_shell:s0
MIBOX_ROOT_COMMAND_CONFIRMED
REMOTE_EXIT:0
```

Evidence: `artifacts/root-investigation/2026-11-13/root-result.txt` and the local
daemon/library copies, string scans and disassembly in the same directory.
This is one command run by an existing privileged daemon; ADB itself remains a
shell process. No su binary, persistent root service, SELinux change, bootloader
change or reboot was requested.

## Why this worked

The device runs /system/bin/pppoe_wrapper as root. Its filesystem socket is
world-writable and /proc/net/unix identifies it as a Unix datagram socket.
The registered `pppd pty` handler at Thumb entry 0xbc0 branches to an interworking
stub at 0xf84; ARM instruction at 0xf8c targets the system PLT at 0x9d4.

The initial unframed request timed out with no identity output. Inspection of
libnetutils.so showed two TAB delimiters are required (0x46c8-0x46fa); the server
must successfully send its ACK before handler dispatch (0x470e-0x472e).
The corrected request uses a bound local client socket and the framing:

```
PID<TAB>request-number<TAB>command
```

`src/bin/mibox-root-check.rs` sends a fixed identity-only command. An incomplete
pppd option is sent before that command; no PPP connection setup is requested.
The resulting identity is written to a known scratch file, made readable, and
checked. The client socket is removed after receiving the ACK.

This matches the mechanism disclosed for Amlogic's pppoe_wrapper in
[CVE-2026-119737](https://www.vulncheck.com/advisories/amlogic-pppoe-wrapper-command-injection-via-af-unix-socket).
The advisory lists other TV boxes; applicability here is supported by the actual
device's daemon analysis and successful identity check, not model-name inference.

## Backup status

Update: USB recovered and the corrected tool completed all seven backups.
Host/device SHA-256 matched for each file. See `docs/mibox-stock-images.md`.
The earlier interruption described below is historical.

`src/bin/mibox-backup-boot.rs` was built for a fixed list: boot, boot1, recovery,
bootloader, env, reserved and logo. It reads bounded counts from block devices
into a new scratch directory and checks resulting file sizes. It never writes
to block devices. No arbitrary-command CLI is provided.

The subsequent USB upload stalled before any upload-complete or backup marker.
After stopping only the agent's stalled host commands and restarting the host
ADB server, the device reported offline. A reconnect attempt removed the offline
transport. No completed partition backup or independent partition-read result
has been obtained. Do not treat root identity as proof that SELinux will allow
partition reads. The cause of the USB interruption is unknown.

Reconnect the Micro USB data cable, verify get-state, then retry backup upload
and execution. Preserve the resulting backups on the PC and verify hashes before
considering any image modification.
