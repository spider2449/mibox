# A32-style automated RAM boot

1. [x] Reuse the A32 orchestration pattern with Mi Box's verified loader protocol.
2. [x] Add one entry point for local checks, ADB loader transition, full RAM verification, custom boot and optional Android return.
3. [x] Validate rejection paths and run local checks without device mutation.
4. [x] Retain usage/provenance and physical results if the automated round trip is run.

Pin the already physical-tested Restart image. No flash, erase, env-save, bulk
transfer, remote-key requirement or automatic retry of a failed mode request.

Five guard cases and local Check passed. Physical round trip passed on
2026-11-14 14:29:58–14:53:19, with complete RAM readback, custom executable
hashes, readiness and independent Android return. No owner action needed.
The host transfer wait was extended during this first run; the persisted
default is now 3600 seconds and passed a new local Check. See
`docs/mibox-automated-ram-boot.md` for the intervention/provenance limit.
