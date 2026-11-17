# Cold-start boot selection (plan C1)

Established 2026-11-17 from the pinned bootloader image, the installed env and
read-only device hashes. No bootloader code was run; no env or partition was
written. This describes the normal (non-USB-burning) path only.

## Result

With the env currently installed on the box, a cold start loads **boot1**
(179:7). Evidence:

1. The env partition (179:3) hashes `6142e34f…`, the installed rescue-window
   image (`artifacts/console-root/20261117-203213-c1-env-hash/`). Its CRC-valid
   first 32 KiB holds `bootsystem=1`, `upgrade_step=0`, no `resetenv`, and
   `storeboot=store read boot1 ${loadaddr} 0 800000;bootm;run recovery`.
2. `switch_bootpart` (handler `0x8f870b7c`, usage "swich boot partition form
   boot or boot1") reads `bootsystem`:
   - `0`: replaces "store read boot1 " with "store read boot " in `storeboot`;
   - `1`: replaces "store read boot " with "store read boot1 ";
   - anything else or unset: no change.
   The replace helper (`0x8f870a9c`) returns the input unchanged when the
   search text is absent, and the result is written back with `setenv`. It also
   appends ` androidboot.system=<bootsystem>` to `boot_args`.
   With `bootsystem=1` and `storeboot` already reading boot1, it stays boot1.
3. Independent observation: Android on 2026-11-13 reported kernel build
   `Mon Feb 20 15:47:21 CST 2017`, which is boot1's kernel (uImage time
   2017-02-20 07:47:46 UTC). boot holds a different kernel (2016-07-27), see
   A3a in the plan.

## The preboot sequence as installed

`preboot` (installed): `update 10000;` (USB loader window), then
`if itest ${upgrade_step} == 1; then defenv; setenv upgrade_step 2; saveenv; fi`,
`secukey emmc; secukey updatehdcpkey; run initenv; switch_bootpart;
modify_cmdline; run storeargs;` `if itest ${upgrade_step} == 3; then run update; fi;`
`get_rebootmode; …; run update_key; run init_display; run switch_bootmode;`.
Then `bootcmd` = `hdcp prefetch emmc; run storeboot` = read boot1, `bootm`,
and if `bootm` returns, `run recovery` (reads and boots the recovery partition).

## Conditions that change the selection

| Condition | Effect |
| --- | --- |
| `bootsystem=0` in env | `storeboot` rewritten to read **boot** (and saved by `storeargs`) |
| `upgrade_step=1` | plain `defenv`: built-in defaults have `bootsystem=0` and a `storeboot` reading **boot**; also drops the installed `update 10000;` window |
| env CRC invalid / reset to defaults | same built-in defaults: **boot**, no USB window |
| `resetenv=1` or `2` | early-init routine `0x8f870dc4` (called every boot from `0x8f806acc` via `0x8f871ac8`) resets env but restores `bootsystem`, `sn`, `serial`, `factorytest`, `updatestat`, `cecconfig` and display values; returns immediately otherwise |
| `bootm` of boot1 returns (image rejected/corrupt) | `run recovery`: stock recovery partition boots |
| `reboot_mode`/IR/BT detections | recovery or `update` per `switch_bootmode`/`update_key` (unchanged analysis) |

## Env writes on every boot

`storeargs` ends with `saveenv`, and `modify_cmdline` calls the same save
backend (`0x8f81cc58`, also used by `saveenv` and the BT path). The env is
therefore rewritten during normal boots. Any env change must keep a valid,
complete env image; partial or default env selects **boot** and loses the
USB window.

## Not established here

- Whether `bootm` verifies any signature or only parses the header (C4/C5).
- Behaviour without a USB host after `update 10000` expires (C2, owner test).
- Elapsed time of `update 10000`.

## Reproduce

```sh
python3 scripts/inspect-loader-bootpart.py     # WSL; needs arm-linux-gnueabihf-objdump
```
Device env hash: `scripts/device/c1-hash-env.sh` (read-only, as root).
Evidence: `artifacts/boot-selection/2026-11-17/`.
