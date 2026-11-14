# Compare exact IR decoders

1. [x] Resolve loader decoder data references and timing bounds from pinned bytes.
2. [x] Compare loader symbol ordering with the exact kernel decoder.
3. [x] Model the recovered symbol transformation with explicit bounds and reject unsupported equivalences.
4. [x] Record recovery-button evidence and remaining physical-test requirements.

Candidate shift-by-two transform passes the kernel checksum but yields 0x8603,
absent from the 29-entry table. Not a proven physical mapping. Separately found
official general IR HOME+MENU cold-start guidance; physical entry remains untested.

Offline only; no register writes, key injection or reboot.
