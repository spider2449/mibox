# Bound observer child processes

1. [x] Inspect the retained Hardware3 failure without changing its evidence.
2. [x] Use the shared bounded process runner for observer ADB queries.
3. [x] Record stdout/stderr completion separately, retaining strict EOF checks.
4. [x] Run host-only process and orchestration regressions; document limitations.

No device access or new RAM boot is needed. The historical stream failure's
cause remains UNKNOWN until reproduced; audible output still needs a suitable sink.

Host results: process runner 5/5 (including exit 0/7 and timeout cleanup),
observer fixtures 4/4 (valid/nonzero/incomplete/timeout), orchestration guards
9/9. Observer failures during reconnect remain recorded; incomplete or failed
identity queries cannot establish the custom OS marker. Each ADB query uses
the shared five-second execution deadline plus bounded cleanup/EOF waits.
This does not establish a fix for the historical outer-wrapper stream failure.

5. [x] Reproduce an exited root with a live descendant holding inherited pipes;
   verify bounded rejection without targeting the exited root's historical PID.

Extended process fixtures passed 6/6. The new case proves root exit 0 with
both EOF waits incomplete, a still-live descendant (PID plus creation time),
bounded rejection and no cleanup targeting the exited root. The retained
fixture child then exits naturally. Evidence:
`artifacts/ram-boot/process-tests-20261115-055956-389/results.json`.
This reproduces a failure mechanism, not the historical hardware root cause.
