# Physical Android remote-input inventory

At 2026-11-14 13:46–13:47 Asia/Taipei, serial 248243005297 was reachable
in the ADB device state. Bounded read-only queries observed original stock
fingerprint Xiaomi/casablanca_icntv/casablanca:4.4.2/KOT49H/2876:user/release-keys,
sys.boot_completed=1, and boot ID f30c821a-8b2c-4ca0-9247-eb6b1d2203bc before
and after the inventory. This matches the earlier successful software return;
it is a checkpoint, not proof of continuous health between observations.

| Runtime input device | Event node | Observation |
| --- | --- | --- |
| ir_meson6 | /dev/input/event0 | Platform ir-meson6-mi, readable capability inventory |
| cec_input | /dev/input/event1 | Virtual HDMI-CEC input, readable capability inventory |

The IR device advertises almost the entire key bitmap. Capability labels are
not a physical-remote keymap or evidence that each key can be generated.
The stock /system/etc/remote.conf and /sys/class/remote paths are absent.
The platform device directory exposes no separate keymap attribute in this
listing. No sysfs value was changed.

An owner-prompted 45-second read of `getevent -lt -c 2 /dev/input/event0`
captured no output and reached the host timeout. Its host process was stopped
and reaped, with exit code -1. This is not evidence of an IR failure or of
the absence of a remote; there is no owner-confirmed key press timestamp in
that window. It also does not rule out control through event1 or another
transport. No input event was injected.

Owner subsequently identified it as the Mi Box remote. The coordinated capture
below establishes actual IR input; owner confirmation of the requested
physical button sequence is still pending.
Do not turn a normal Android keycode into a bootloader button sequence without
raw-code or exact-driver evidence. Independent recovery/loader entry remains
unverified; permanent installation remains NOT READY.

Evidence:

- [First identity and input inventory](../artifacts/remote-input/20261114-134609/result.json)
- [Bounded event capture with no observed input](../artifacts/remote-input/20261114-134609/back-event.json)
- [Follow-up sysfs and identity inventory](../artifacts/remote-input/20261114-134701/result.json)

Reproduce inventory with `powershell -NoProfile -File scripts/Collect-MiboxRemoteInput.ps1`.
Each ADB query has an eight-second host deadline and retained stdout/stderr.
No device files were written, reboot requested, USB reconfigured or firmware
executed by the host tools. Normal Android and owner UI actions can have their
own persistent effects.

## Subsequent physical capture and exact kernel table

At 13:49:00–13:49:23 Asia/Taipei, a new bounded event0 capture completed with
host exit code 0 and no timeout. It retained 12 events: MENU press/release,
MENU press/release, BACK press/release, each with SYN_REPORT. This proves
actual IR events were received. It differs from the requested BACK/UP/DOWN
sequence, so the request must not be marked physically verified.

[Actual capture](../artifacts/remote-input/capture-20261114-134900/capture.json).
The expected timeout at the earlier 13:46 attempt is superseded only as to
whether events can be read, not retrospectively changed into a successful
capture.

Offline analysis of the exact stock kernel recovered its 29-entry IR table.
The recovered ELF hash was pinned and its load segment compared byte-for-byte
with the hash-pinned expanded stock kernel before using addresses. Audited
instructions in ir_fiq_interrupt derive the identifier as
`(kernel_assembled_word >> 4) & 0xffff`, then search 29 pairs of 32-bit fields.
Selected entries:

| Kernel IR identifier | Linux keycode | Meaning corroborated by input labels/config |
| --- | --- | --- |
| 0x8605 | 103 | UP |
| 0x860d | 28 | ENTER |
| 0x8606 | 108 | DOWN |
| 0x860b | 105 | LEFT |
| 0x860c | 106 | RIGHT |
| 0x8607 | 158 | BACK |
| 0x8604 | 139 | MENU |

The bootloader's assembled-value comparison 0x002180f4 and this kernel's
identifier expression belong to different decoding paths. Their format
equivalence has not been demonstrated; truncating/shifting the loader value
does not establish its physical button. Cold-start recovery keys remain
UNKNOWN. No reboot or key injection occurred.

Reproduce offline with `scripts/inspect-kernel-ir-map.py` under WSL Python3.
[All 29 table entries and provenance](../artifacts/remote-input/kernel-ir-map/map.json)
and [driver disassembly](../artifacts/remote-input/kernel-ir-map/ir-fiq-disassembly.txt)
are retained. The additional read-only kernel-log snapshot at
`artifacts/remote-input/20261114-135024/` contained the IR registration line but
no matching raw-key diagnostics under the retained filter; logging settings
were not changed.

## Owner-confirmed retry

The owner requested another capture and reported completion of the requested
BACK/UP/DOWN sequence. The 13:53:28–13:55:28 capture received only KEY_DOWN
press and release plus two SYN_REPORT events (four records). It reached the
120-second host deadline before the configured count of 12. The retained
host exit code is -1 after timeout cleanup; partial events remain valid
observations. No BACK or UP event was observed in this window. The cause of
the missing events is UNKNOWN; do not infer incorrect owner operation or a
broken remote. A subsequent get-state query returned device.

[Retry and owner-completion annotation](../artifacts/remote-input/capture-20261114-135328/capture.json).
OwnerCompletionReported records the user's report; it does not certify that
the observed sequence matched the request. Future coordinated capture should
use one button per window to avoid treating an incomplete group as a full
mapping. No reboot, input injection or logging setting change occurred.

## Single BACK retry

The owner agreed to a single-button test and reported completion. The
13:56:32–13:58:32 event0-only capture requested four records but received no
stdout or stderr before its 120-second deadline. Timeout cleanup retained
host exit code -1. A read-only input-device query during the window still
listed ir_meson6/event0 and cec_input/event1. Other input sources were not
monitored by this capture; the cause remains UNKNOWN. This does not establish
whether the Android screen reacted to the owner's BACK press.

[Single BACK attempt](../artifacts/remote-input/capture-20261114-135632/capture.json).
No reboot or input injection occurred. Before asking for further repeated
presses, clarify whether the on-screen action occurred; any subsequent capture
should include both existing input sources to test the event0-only assumption.

## Confirmed single BACK capture

At 14:03:30–14:03:46 Asia/Taipei, all-source capture completed with host exit
code 0 and no timeout. It received KEY_BACK DOWN and KEY_BACK UP, each followed
by SYN_REPORT, from /dev/input/event0 (ir_meson6). The owner then confirmed
completion of the single requested BACK press. This establishes the physical
BACK button's IR input path and Linux key label for this test. No event1 key
event was observed in this capture. The mice-version diagnostic is unrelated
to the successfully received event0 records.

[Confirmed BACK evidence](../artifacts/remote-input/capture-20261114-140330/capture.json).
The exact kernel table maps BACK keycode 158 to identifier 0x8607; this remains
separate from bootloader recovery-trigger format equivalence. No input event
was injected or reboot requested. Owner explicitly excluded TV/home-screen
investigation; that separate display/launcher issue was not pursued.

## Confirmed single UP capture

At 14:04:52–14:05:11 Asia/Taipei, all-source capture completed with host exit
code 0 and no timeout. KEY_UP DOWN and KEY_UP UP, each with SYN_REPORT, came
from /dev/input/event0 (ir_meson6). The owner confirmed completing the single
requested UP press. The kernel table maps UP keycode 103 to identifier 0x8605.
No input was injected and no reboot requested.

[Confirmed UP evidence](../artifacts/remote-input/capture-20261114-140452/capture.json).

## Confirmed single DOWN capture

At 14:05:50–14:06:07 Asia/Taipei, all-source capture completed with host exit
code 0 and no timeout. KEY_DOWN DOWN and KEY_DOWN UP, each with SYN_REPORT,
came from /dev/input/event0 (ir_meson6). The owner confirmed completing the
single requested DOWN press. The kernel table maps DOWN keycode 108 to
identifier 0x8606. No input was injected and no reboot requested.

[Confirmed DOWN evidence](../artifacts/remote-input/capture-20261114-140550/capture.json).
The separate single-button BACK, UP and DOWN tests now all have matching
event0 press/release records and owner completion reports. Bootloader
recovery-trigger equivalence remains a separate unresolved question.
