# Runtime health follow-up, 2026-11-21

1. [x] Reconcile the latest committed installation and Docker acceptance evidence.
2. [x] Collect a read-only SSH snapshot, complete kernel log and published HTTP response.
3. [x] Update the current status in the README and Docker overview.
4. [x] Record kernel warnings and acceptance limits for the next investigation.

Evidence: `artifacts/health/20261121/`. Linux 3.10.99, Docker 28.3.3,
one running `mibox-web` container, HTTP 200 on port 8080, 1.7 GiB free on data,
and `MIBOX_ALPINE_INTEGRITY=MATCH` were observed. Boot ID:
`0db89f9b-4414-4b75-9c4d-8992295dc278`. This snapshot covers about two minutes
of uptime; it does not establish long-duration stability or boot provenance.

The first probe incorrectly used thermal_zone0 (absent). The SARADC channel-6
read returned 623, approximately 56 C using the existing untrimmed formula.
The Alpine chroot cannot see the outer RAM root's `/run/mibox-cpu-temp` marker;
its missing path here does not establish failure of the HDMI status process.
No visual HDMI check was performed.

The complete dmesg contains sleeping-in-atomic diagnostics in secondary CPU
IRQ setup and Ethernet ring allocation, plus an SMP warning through
`clk_set_rate_a9`. Services continued starting, but the kernel log is not clean.
Next technical work: trace these vendor call paths against the pinned source,
prepare offline fixes and validation before considering another kernel image.
Also recorded: unsupported ext4 discard and cgroup hierarchy warnings.

Power-loss acceptance (system redesign C5a), actual partition restoration,
overlayfs and a pids controller remain separate unfinished work. This follow-up
performed no reboot, service change or partition write.
