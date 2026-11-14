# Mi Box OTA and partition investigation (2026-11-13)

## Acquired from the attached device

Read via USB ADB and copied locally without executing update code:

- /system/vendor/app/MiTVUpgrade.apk (1936274 bytes)
- /system/lib/libupdate.so (246164 bytes)
- /system/lib/libupdateservice.so (70868 bytes)

Files, printable-string scans, library disassembly and SHA-256 manifest are in
`artifacts/ota-investigation/2026-11-13/`. Printable strings are leads, not proof
that a given function executes or a service is currently available.

## Download lead

libupdate.so contains these strings together:

```
ro.product.name
ro.build.date.utc
ro.build.version.incremental
%s/%s/%s/%s/%s
https://os.cdn.pandora.xiaomi.com/product
boot.img
```

The device properties are casablanca_icntv, 1487576742 and 2876. Two inferred
paths were tested with HTTP HEAD from the development PC:

- /product/casablanca_icntv/1487576742/2876/boot.img
- /product/casablanca_icntv/2876/1487576742/boot.img

Both returned HTTP 404. Path ordering has NOT been established by data-flow
analysis, so these responses do not prove the matching image is absent from the
CDN. Standard TLS validation failed; the diagnostic HEAD probes used curl
--insecure. No firmware was downloaded and no TLS trust setting was changed.
Future downloaded content needs independent validation against device evidence.

MiTVUpgrade.apk also contains upgrade.duokanbox.com, upgrade.g.duokanbox.com,
upgrade.t001.ottcn.com and package.box.duokanbox.com. These are static strings;
no update service, broadcast, native installer or update check was invoked.

## Archive availability

- https://firmwaredrive.com/files/32780 lists an older
  Casablanca GiTV 1.3.112D.1868 OTA and requires sign-in to download.
- https://firmwarefile.com/xiaomi-mi-box-1s/ returned HTTP 403 to the browsing tool.
- https://www.znds.com/tv-487521-1-1.html links an older MDZ-06-AA 1.3.88 package
  on Baidu. This is not the device's installed build 2876.

These are discovery leads, not authenticated firmware provenance. No account
was created or used, no paid download attempted, and no archive was flashed.
Selected shared-storage backup/download/system/vrom directories contained no
matching .img/.zip/update candidate in their accessible listings.

## Confirmed partition geometry

Unlike guessed mmcblk0pN sysfs paths, this vendor kernel exposes partition names
directly under /sys/class/block. Read `dev`, `start` and `size` there.
`scripts/Collect-MiboxPartitions.ps1` records these fields and derives bytes
using Linux block sysfs 512-byte sector units. The script was run successfully;
raw output and JSON are under `artifacts/partitions/`.

| Partition | Offset bytes | Size bytes |
| --- | ---: | ---: |
| recovery | 12582912 | 8388608 |
| boot | 20971520 | 8388608 |
| boot1 | 29360128 | 8388608 |

These are geometry measurements, not instructions to write mmcblk0. A name or
second slot does not prove which boot partition is active or provide rollback.
No block-device content was obtained. Boot packaging and loader acceptance
remain unknown.

## Next useful evidence

URL argument order is now established by static analysis; see
`docs/mibox-cdn-url-trace.md`. The confirmed URL is the second tested path and
returned 404. Next obtain read access to boot through a verified recovery/root
path, or obtain a matching image from another archive.
If an image is acquired, compare its first 4433609 bytes with the SHA-1 declared
in the installed recovery script before treating it as the expected boot source.
