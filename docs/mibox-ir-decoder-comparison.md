# IR decoder comparison and recovery-entry candidate

The pinned loader's PC-relative data references resolve an initial shift of
20 and a step of 2. Its nonnegative accumulation positions are 20,18,...,0
(11 symbols). The kernel decoder instead completes its data/checksum word at
10 symbols and extracts a 16-bit identifier after dropping a checksum nibble.
All data was read from pinned backups; BSS pointers were recorded as pointers,
not treated as file-backed values.

One candidate relationship is a shared symbol interpretation followed by an
extra trailing symbol in the loader. Under that assumption:

| Value | Result |
| --- | --- |
| Loader target | 0x002180f4 |
| Candidate kernel word, target >> 2 | 0x0008603d |
| Candidate identifier | 0x8603 |
| Candidate checksum nibble | 0xd |
| XOR of identifier nibbles | 0xd |

The checksum matches, but identifier 0x8603 is absent from all 29 driver table
entries. No table entry, encoded with the kernel checksum and a trailing zero
symbol under this model, equals the loader target. This does not prove an
unmapped hardware button or any particular button combination. The shared
symbol interpretation, timing equivalence and extra-trailer relationship have
not been demonstrated with a captured waveform. This remains a **candidate**.

The actual loader timing initializer produces raw counter pairs
(305,329), (219,249), (271,299), (335,355), (399,513). The comparison script
derives these by decoding the inspected MOVW/MOV/ADD instructions. Its report
does not convert them to kernel nanoseconds; loader counter units remain
UNKNOWN in this bounded audit.

Reproduce with WSL Python3 `scripts/compare-ir-decoders.py` after the earlier
kernel-map and loader-address audits. [Report and all modeled table entries](../artifacts/remote-input/kernel-ir-map/decoder-comparison.json).
This script accesses local files only and checks source hashes and audited
instruction words. No device register, logging setting or boot state changed.

## Separately sourced physical entry candidate

[Xiaomi's official recovery guidance](https://www.mi.com/service/box/update)
specifies holding HOME and MENU on an infrared remote while reconnecting
power to the box, aiming at its front receiver, then releasing on the recovery
screen. This guidance is for IR-capable boxes generally; the exact MDZ-06-AA
test is not yet demonstrated here. The official IR procedure is separate
evidence, not confirmation that its chord emits identifier 0x8603.

The site search index returned the recovery article text; opening the URL
directly returned a generic site/navigation rendering. Preserve that retrieval
limitation instead of describing the article as an exact-device manual.
The existing device evidence independently confirms a preboot irdetect branch
invoking recovery and actual IR events from the owner's Mi Box remote.

A prospective cold-start test should observe entry only. Do not select wipe,
factory restore, system switching or update actions; supply no update media.
Host observation must be armed before the owner power/remote action. Reaching
a menu is not proof of an ADB shell, partition restoration or independent USB
loader entry. Stock boot/recovery code may make its own persistent writes.
Permanent installation remains **NOT READY**.
