# libupdate.so boot URL assembly

Input: `artifacts/ota-investigation/2026-11-13/libupdate.so`, copied from the
attached MiBOX1S. This is static analysis; the updater has not been executed.
Disassembly: `libupdate-disassembly.txt` in the same directory.

## Confirmed constant references

The ARM Thumb instructions load PC-relative literal offsets. Resolve each
literal through the ELF PT_LOAD mapping and add the PC of the corresponding
ADD instruction (instruction address + 4). The following addresses resolve to:

| Literal address | Resolved virtual address | String |
| --- | --- | --- |
| 0x9a80 | 0x30d51 | ro.product.name |
| 0x9a84 | 0x30d61 | ro.build.date.utc |
| 0x9a88 | 0x30d73 | ro.build.version.incremental |
| 0x9aa0 | 0x30de9 | https://os.cdn.pandora.xiaomi.com/product |
| 0x9aa4 | 0x30e13 | boot.img |
| 0x9aa8 | 0x30dda | %s/%s/%s/%s/%s |

## Argument flow

- `property_get` at 0x97c0 stores product name at sp+184 (sl).
- `property_get` at 0x97d0 stores build date at sp+276 (r8).
- `property_get` at 0x97dc stores incremental at sp+368 (r9).
- Call to `__sprintf_chk` at 0x9854 uses r0/r1/r2/r3 for destination,
  checking flag, buffer size and format. The five variadic string arguments
  are on the stack at offsets 0, 4, 8, 12, 16: CDN base, product, incremental,
  build date, boot.img respectively (instructions 0x9830 through 0x9852).

Thus this branch constructs:

```
https://os.cdn.pandora.xiaomi.com/product/casablanca_icntv/2876/1487576742/boot.img
```

This confirms the second previously tested URL's argument ordering. Its HEAD
response was 404; no image was acquired. The alternative branch at 0x986a uses
a different format ending `%s%s` for a parsed file path. This does not prove that
the updater will enter either branch on the current system or that no other
download service has the image.

A subsequent GET against that exact URL also returned 404 (curl exit 22).
Headers are preserved in `confirmed-url-get-headers.txt`. TLS validation was
disabled for this diagnostic request as in the previous HEAD probe; no payload
was obtained. The candidate inspector was exercised against the recovery delta:
it reported UNKNOWN format, no prefix match, and exited 1 as expected. Actual
boot-header parsing remains untested against a real Mi Box boot image.

## Candidate validation tool

`scripts/inspect-mibox-boot.py` compares a candidate's first 4433609 bytes with
the installed script's boot SHA-1. It optionally inspects a bounded Android
v0-compatible layout; unknown vendor formats remain UNKNOWN. It does not strip
signatures, repack, or produce a flashable image. Exit 0 means the expected
prefix matched; exit 1 means it did not; exit 2 indicates an inspection error.
Neither a prefix match nor a valid layout proves bootloader acceptance.

```
python3 scripts/inspect-mibox-boot.py /path/to/candidate.img
```
