# Remote input inventory

1. [x] Check bounded ADB connectivity and current OS identity.
2. [x] Read input-device capabilities and existing remote configuration where accessible.
3. [x] Match runtime evidence to the offline IR/BT paths before choosing any cold-start test.

Owner confirms the remote can control the box. Read-only queries only;
no key injection, reboot, USB mode change, root deployment or partition writes.

Stock Android verified at the checkpoint. IR event0 and CEC event1 present;
IR advertises almost every key. A 45-second event0 capture timed out with no
events. Owner remote type clarification pending before another capture.
Later owner identified the Mi Box remote. A coordinated capture completed and
received MENU/MENU/BACK from event0. This establishes IR reception but differs
from the requested sequence. Exact kernel table extracted; loader/kernel raw
format equivalence remains UNKNOWN, so no cold-start test was selected.
See `docs/mibox-remote-input.md`.
