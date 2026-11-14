# Host restoration rehearsal

1. [x] Implement a host-only rehearsal with pinned boot1 size/hash and disposable targets.
2. [x] Check complete readback and rejection of wrong identity, size, hash and source/target alias.
3. [x] Inject interruption and readback corruption; require failure without a success record.
4. [x] Retain machine-readable results and document the remaining physical rescue gates.

WSL Ubuntu-24.04 Python3: 11/11 cases passed. Physical restoration remains
untested. Report: `artifacts/restoration/2026-11-14/host-rehearsal.json`.

No device operations or block-device restoration implementation in this step.
