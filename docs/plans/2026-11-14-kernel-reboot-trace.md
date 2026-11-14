# Trace the stock kernel's software reboot command

1. [x] Observe usb_burning request, no loader USB ID, and automatic Android return.
2. [x] Identify usb_burner_reboot string in the exact expanded stock kernel.
3. [x] Recover symbols offline using a pinned tool in an isolated Python environment.
4. [x] Trace actual comparison/return-value mapping before another mode request.
5. [x] If the command is confirmed, repeat enumeration-only test with owner power fallback.

No kernel patching, kptr_restrict changes or assumed literal base addresses.
The saved U-Boot name need not equal the kernel reboot argument. Keep public
reference source distinguished from the actual device binary.

55,558 symbols recovered. meson_common_restart at 0xc002cf60 compares
usb_burner_reboot and selects 0x09090909. usb_burning matches no case and takes
the default 0x01010101 path. The recovered ELF kernel segment was checked
byte-for-byte against the verified raw kernel before accepting disassembly.
