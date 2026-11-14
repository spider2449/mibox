# Independent rescue entry investigation

1. [x] Verify pinned saved environment and bootloader backups.
2. [x] Trace saved pre-Android recovery triggers and persistence hazards.
3. [x] Inventory bounded bootloader strings and container signatures without assuming a load base.
4. [x] Record what can be tested without hardware modification and identify any required owner action.

Candidate: preboot remote detection enters recovery. Key values and actual
cold-start behavior UNKNOWN. Owner remote availability requested before a
physical entry test; no loader-entry independence claim. Results retained in
`artifacts/restoration/2026-11-14/rescue-entry.json`.

Offline analysis only; no remote-key injection, boot-mode request, reboot,
environment mutation or storage write.
