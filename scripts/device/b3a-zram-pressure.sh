#!/bin/sh
# B3a bounded zram swap pressure test, run as root inside the persistent Alpine
# tree. Runtime-only: zram is torn down and reset on exit (also on failure).
# Workload: python3 allocates pages that are 1 KiB random + 3 KiB repeated
# pattern (no all-zero pages, which zram stores specially), in 32 MiB steps up
# to TARGET_MIB, and stops early if SwapFree < 64 MiB or a step takes > 20 s.
# OOM is not exercised on purpose.
set -eu
DISK_MIB=${DISK_MIB:-448}
TARGET_MIB=${TARGET_MIB:-960}
z=/sys/block/zram0
node=/dev/mibox-zram0
test "$(cat $z/initstate)" = 0
test -z "$(awk 'NR > 1' /proc/swaps)"
teardown() {
    swapoff "$node" 2>/dev/null || true
    echo 1 > "$z/reset" 2>/dev/null || true
    rm -f "$node"
    echo "TEARDOWN initstate=$(cat $z/initstate) disksize=$(cat $z/disksize) swaps=$(awk 'NR > 1' /proc/swaps | wc -l)"
}
trap teardown EXIT
rm -f "$node"
mknod -m 600 "$node" b 253 0
echo $((DISK_MIB * 1024 * 1024)) > "$z/disksize"
mkswap "$node" > /dev/null
swapon -p 100 "$node"
echo "SWAP_ON disk_mib=$DISK_MIB swappiness=$(cat /proc/sys/vm/swappiness)"
sync
python3 - "$TARGET_MIB" <<'PY'
import os, sys, time
target = int(sys.argv[1])
def meminfo():
    d = {}
    for line in open('/proc/meminfo'):
        k, v = line.split(':')
        d[k] = int(v.split()[0])
    return d
def zram(name):
    return int(open('/sys/block/zram0/' + name).read().split()[0])
pattern = (b'mibox-zram-b3a!' * 205)[:3072]
chunks, allocated, stop = [], 0, 'target reached'
print('STEP mib step_s MemFree_kib SwapUsed_kib orig_kib compr_kib zram_mem_kib', flush=True)
start = time.monotonic()
while allocated < target:
    t = time.monotonic()
    page_block = bytearray()
    for _ in range(32 * 256):  # 32 MiB of 4 KiB pages
        page_block += os.urandom(1024) + pattern
    chunks.append(page_block)
    allocated += 32
    step = time.monotonic() - t
    m = meminfo()
    swap_used = m['SwapTotal'] - m['SwapFree']
    print('STEP', allocated, f'{step:.2f}', m['MemFree'], swap_used, zram('orig_data_size') // 1024,
          zram('compr_data_size') // 1024, zram('mem_used_total') // 1024, flush=True)
    if m['SwapFree'] < 64 * 1024:
        stop = 'SwapFree below 64 MiB'; break
    if step > 20:
        stop = 'step slower than 20 s'; break
# Touch everything once more: forces swapped pages back in (read path).
t = time.monotonic()
total = sum(c[0] + c[-1] for c in chunks)
print(f'REREAD_S {time.monotonic() - t:.2f} checksum {total}', flush=True)
orig, compr, used = zram('orig_data_size'), zram('compr_data_size'), zram('mem_used_total')
ratio = f'{orig / compr:.2f}' if compr else 'n/a'
print(f'RESULT allocated_mib={allocated} stop="{stop}" total_s={time.monotonic() - start:.1f} '
      f'zram_orig_kib={orig // 1024} zram_compr_kib={compr // 1024} zram_mem_kib={used // 1024} ratio={ratio}',
      flush=True)
PY
echo "AFTER_WORKLOAD $(grep -E '^(MemFree|SwapTotal|SwapFree):' /proc/meminfo | tr -s ' ' | tr '\n' ' ')"
dmesg | grep -i -E 'oom|killed process|page allocation failure' | tail -5 || true
echo B3A_PRESSURE_DONE
