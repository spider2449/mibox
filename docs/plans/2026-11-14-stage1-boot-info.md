# Stage-one boot information audit

1. [x] Derive stage-one link base and boot-info pointer chain from pinned backup.
2. [x] Compare the consumed field with the expanded loader's startup override.
3. [x] Inspect internal/external loading branches and retain bounded disassembly.
4. [x] Report the field's meaning and the limits of writer/physical-entry evidence.

Confirmed shared boot-info second word. Value 1 selects ext dev at stage one;
other values select int dev there. Public pinned source labels it boot_id.
Initial writer and physical cold-start control remain UNKNOWN.

Host-only analysis; no device access, media creation or register operations.
