# MiBOX1S boot-image evidence

Update: complete raw boot, boot1 and recovery backups have now been acquired;
see `docs/mibox-stock-images.md`. Missing-image statements below describe the
earlier delta-only investigation.

Collected 2026-11-13 via USB ADB from serial 248243005297, running Android
7.2.20.2876. Files are under `artifacts/boot-evidence/2026-11-13/`.

## Files acquired

- `/system/etc/install-recovery.sh`: 455 bytes.
- `/system/recovery-from-boot.p`: 740612 bytes, IMGDIFF2.
- `/system/etc/recovery-resource.dat`: 1533608 bytes, bonus input referenced
  by the installation script.

The script declares these expected image prefixes:

| Image | Bytes | SHA-1 declared by script |
| --- | ---: | --- |
| boot source | 4433609 | 2dafa19e539ef3a5a674d3f13ff6df9ab483220f |
| recovery target | 6794846 | e94825710e912cc47f09dee1be17fb43d1fc564d |

These are expectations in the installed system files, NOT hashes measured from
the current raw partitions. They need not equal the full 8 MiB partition hashes.
No `applypatch` command was executed; it would write recovery.

## Patch metadata

`scripts/inspect-recovery-patch.py` parsed the actual patch using AOSP IMGDIFF2
field definitions. It does not apply a patch, decompress payloads, or prove
payload integrity. `patch-layout.json` contains the complete metadata.

| Chunk | Type | Source start | Source bytes | BSDIFF output bytes |
| --- | --- | ---: | ---: | ---: |
| 0 | Normal | 0 | 3901450 | 3901450 |
| 1 | Deflate | 3901450 | 519611 | 3736576 expanded |
| 2 | Normal | 4421061 | 12548 | 12334 |

Source ranges are contiguous and end at 4433609, matching the script's expected
boot source length. The Deflate chunk declares source expanded length 2441640;
because bonus data is used, this must not be equated with the source ramdisk size
without inspecting the actual source image and patch application semantics.
No kernel or ramdisk boundaries are claimed from chunk boundaries alone.

## Provenance and reproduction

The AOSP source was read as text, not compiled or executed:
https://android.googlesource.com/platform/bootable/recovery/+/android-4.4.2_r1/applypatch/imgdiff.c

```sh
python3 scripts/inspect-recovery-patch.py \
  artifacts/boot-evidence/2026-11-13/recovery-from-boot.p
```

The local `aosp-imgdiff.c` is a decoded text reference, not a Mi Box source file.
`sha256.csv` tracks acquired evidence files. Hashes are local provenance, not
vendor signature verification.

## Still required

Neither a complete boot nor recovery image has been obtained. Direct reads of
both block devices are denied to shell. Searches found older casablanca firmware
listings but no verified match for build 2876; none were downloaded or installed.
`/backup` is inaccessible and no usable cached update was found in the directories
checked. This is not an exhaustive search of root-only storage.

Next obtain the matching image from a trustworthy archive, or establish read-only
partition access/recovery console. Then compare actual image hashes with the
script and inspect image magic, section bounds, load addresses and trailers.
No flashable image should be constructed from these delta files alone.
