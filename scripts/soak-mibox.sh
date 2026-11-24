#!/bin/bash
# Long-duration health soak of the installed system, read-only over SSH.
# Every INTERVAL seconds for DURATION seconds, append one TSV line: boot ID,
# uptime, load, memory, data free, SoC temperature, process/fd counts, default
# route, netwatch, running containers, HTTP on :8080 and the number of kernel
# atomic-context/BUG/WARNING lines. A boot ID change or a failed probe is
# recorded, not acted on. Nothing on the box is changed.
# Usage (WSL): scripts/soak-mibox.sh [DURATION_S] [INTERVAL_S]
set -u
duration=${1:-86400}; interval=${2:-300}
repo=$(cd "$(dirname "$0")/.." && pwd); cd "$repo"
ev=artifacts/soak/$(date +%Y%m%d-%H%M%S); mkdir -p "$ev"
keysrc=$(wslpath -u "$(cmd.exe /c echo %USERPROFILE% 2>/dev/null | tr -d '\r')")/.ssh/mibox-console
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT; cp "$keysrc" "$tmp/key"; chmod 600 "$tmp/key"
ssh_() { ssh -i "$tmp/key" -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes \
  -o UserKnownHostsFile=assets/ssh/mibox-persistent-known-hosts -o ConnectTimeout=5 \
  -o ServerAliveInterval=5 -o ServerAliveCountMax=3 root@192.168.1.222 "$@"; }
probe='set -u
b=$(cat /proc/sys/kernel/random/boot_id); u=$(cut -d" " -f1 /proc/uptime)
l=$(cut -d" " -f1-3 /proc/loadavg | tr " " /)
m() { awk -v k="$1:" "\$1==k{print \$2}" /proc/meminfo; }
f=$(df -k / | awk "NR==2{print \$4}")
t=$(cat /sys/class/saradc/saradc_ch6 2>/dev/null || echo -)
p=$(ls /proc | grep -c "^[0-9]"); fd=$(cut -f1 /proc/sys/fs/file-nr)
r=$(ip route | grep -c "^default "); n=$(ps | grep -c "[m]ibox-netwatch")
c=$(docker ps -q 2>/dev/null | wc -l)
w=$(dmesg | grep -c -E "sleeping function called|scheduling while atomic|BUG:|WARNING: at|Oops")
printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$b" "$u" "$l" "$(m MemFree)" "$(m Cached)" "$(m Slab)" "$f" "$t" "$p" "$fd" "$r$n" "$c" "$w"'
printf 'utc\tboot_id\tuptime_s\tload1/5/15\tmemfree_kib\tcached_kib\tslab_kib\tdata_free_kib\tsaradc_ch6\tprocs\tfds\troute+netwatch\tcontainers\tkernel_warn_lines\thttp\n' > "$ev/samples.tsv"
ssh_ dmesg > "$ev/dmesg-start.txt" 2>&1
echo "soak start $(date -u +%FT%TZ) duration=${duration}s interval=${interval}s" > "$ev/run.txt"
end=$(( $(date +%s) + duration ))
while [ "$(date +%s)" -lt "$end" ]; do
  now=$(date -u +%FT%TZ)
  line=$(ssh_ "$probe" 2>/dev/null) || line="PROBE_FAILED"
  http=$(curl -s -m 10 -o /dev/null -w '%{http_code}' http://192.168.1.222:8080/ || true)
  printf '%s\t%s\t%s\n' "$now" "$line" "${http:-000}" >> "$ev/samples.tsv"
  sleep "$interval"
done
ssh_ dmesg > "$ev/dmesg-end.txt" 2>&1
echo "soak end $(date -u +%FT%TZ)" >> "$ev/run.txt"
echo "$ev"
