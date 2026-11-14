# Bound software-return verification

1. [x] Replace unbounded ADB exit/stream waits with the shared retained-process runner.
2. [x] Keep the restart request single-shot and independently verify Android return.
3. [x] Exercise normal return, failed identity, incomplete streams and timeout offline.
4. [x] Document results and preserve historical interrupted evidence unchanged.

No device restart or flash is needed. These checks establish host orchestration
behavior, not the cause of the previous interrupted return observer.

Host fixtures passed 10/10: valid return; identity nonzero/incomplete/timeout
refused before restart; single request with disconnect; return query
nonzero/incomplete/timeout/old boot/incomplete Android rejected before a later
valid response. Each post-request case sent exactly one restart request.
Evidence: `artifacts/software-return/host-tests-20261115-0648/results.json`.
Actual retained-process suite also passed 6/6:
`artifacts/ram-boot/process-tests-20261115-064749-572/results.json`.
