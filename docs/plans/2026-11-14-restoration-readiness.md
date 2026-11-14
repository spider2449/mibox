# Offline restoration readiness

1. [x] Rehash the seven named partition backups and both system images against retained device-verified manifests.
2. [x] Rehash all sixteen system chunks and check contiguous coverage.
3. [x] Record recovery scope, excluded incomplete images and outstanding restore gates.

Result: all 25 files passed local length/hash verification. Permanent install
remains NOT READY; see `docs/mibox-restoration-readiness.md`.

Scope: local backup reads and reports only. No ADB, USB loader, device writes,
reboots, partition changes or restoration execution.
