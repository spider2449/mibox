# Continue custom Linux boot evidence

1. [x] Review boot readiness and verify available runtime namespace interfaces.
2. [x] Analyze recovery trailing data against its independently pinned prefix.
3. [x] Inspect stock recovery startup and restoration scripts offline.
4. [x] Record reproducible findings and remaining hardware boot gates.

Results: docs/mibox-boot-readiness-2026-11-14.md. Recovery tail includes a second
valid FDT beyond the installed script's target prefix. Recovery automatic ADB
and usable kexec are unconfirmed. No additional reboot or boot image write.

Keep the verified persistent USB ADB hook. Do not switch USB functions, modify
boot partitions or reboot into recovery before a usable return path is known.
The live namespace directory exposes only mnt; isolated PID1 testing is not
established on this kernel. Generic QEMU PID1 success remains separate evidence.

Owner constraint: proceed through software only; do not require disassembly,
soldering or other hardware modification. UART is an optional diagnostic,
not an owner-required prerequisite. Investigate software loader/recovery paths.

Diagnostic incident: a quoted grep alternation was flattened by legacy adb's
remote shell parsing, which executed the `reboot` alternative as a command.
Stop remote regex pipelines; collect raw output and filter on the host instead.
No flash/format operation was included. Verify ADB and boot ID after restart.
