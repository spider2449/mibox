# Stock recovery interface investigation

1. [x] Extract the exact recovery executable from the hash-pinned stock image using bounded cpio parsing.
2. [x] Inventory input/menu/ADB strings and ELF symbols offline.
3. [x] Distinguish string presence from reachable behavior; retain evidence and next gates.

Found recovery.kl and four input mapping rows. ELF has no symbol table.
Bootloader cold-start keys and usable recovery shell remain UNKNOWN.
See `docs/mibox-recovery-interface.md`.

No recovery boot, UI selection, reset, update or device operation.
