# Exact bootloader UCL extraction

1. [x] Parse the UCL container discovered at saved bootloader offset 0x8000.
2. [x] Decode with a package-hash-verified safe UCL decompressor; verify block sizes, end marker and Adler32.
3. [x] Inventory expanded loader strings for remote detection and rescue commands.
4. [x] Retain provenance and report exact-binary evidence separately from public reference behavior.

Expanded 736816 bytes with matching Adler32. Derived link base and command
registrations; traced raw IR equality constant and shared BT/saveenv backend.
See `docs/mibox-bootloader-ucl.md`; physical remote keys remain UNKNOWN.

Host-only extraction; no firmware execution, device operations or image creation.
