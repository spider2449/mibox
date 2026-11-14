# Read-only userspace health snapshot

Keep the stock kernel and DTB; no device operations or boot-image packaging.

1. [x] Add a bounded, read-only runtime snapshot to the standalone toolbox.
2. [x] Expose the snapshot through the PID1 console.
3. [x] Test missing/malformed procfs values and build static ARM binaries.
4. [x] Run generic ARM QEMU console checks and retain separate provenance.

Five parser/read-bound tests passed. Normal and no-gadget fallback QEMU runs
each passed 11/11 stages. ARM ELF32 checks found no DYNAMIC or INTERP headers
in either binary. Formatting passed. Evidence: artifacts/userspace-health/2026-11-14/.

Missing or invalid values report UNKNOWN. A snapshot is not a health verdict,
continuous monitoring, hardware validation or replacement-kernel readiness.
