#!/bin/bash
# C5: wait for the box to answer SSH over the LAN (no USB) after an owner
# power cycle; record timing, identity, persistence and integrity state.
# Usage (WSL): scripts/watch-c5-ssh.sh EVIDENCE_DIR [TIMEOUT_S]
set -u
ev=${1:?evidence dir}; limit=${2:-900}
repo=$(cd "$(dirname "$0")/.." && pwd); cd "$repo"
keysrc=$(wslpath -u "$(cmd.exe /c echo %USERPROFILE% 2>/dev/null | tr -d '\r')")/.ssh/mibox-console
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT; cp "$keysrc" $tmp/key; chmod 600 $tmp/key
ssh_() { ssh -i $tmp/key -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes \
  -o UserKnownHostsFile=$ev/known_hosts -o ConnectTimeout=2 root@192.168.1.222 "$@"; }
start=$(date +%s); echo "watch_start_utc=$(date -u +%FT%TZ)" > $ev/watch.txt
seen_down=0
while :; do
  now=$(date +%s)
  [ $((now - start)) -gt "$limit" ] && { echo "TIMEOUT after ${limit}s" | tee -a $ev/watch.txt; exit 1; }
  if out=$(ssh_ 'cat /proc/sys/kernel/random/boot_id /proc/uptime' 2>/dev/null); then
    if [ "$seen_down" = 1 ]; then
      echo "ssh_up_utc=$(date -u +%FT%TZ) after_watch_s=$((now - start))" | tee -a $ev/watch.txt
      echo "$out" | tee -a $ev/watch.txt
      break
    fi
  else
    if [ "$seen_down" = 0 ]; then echo "ssh_down_utc=$(date -u +%FT%TZ)" | tee -a $ev/watch.txt; seen_down=1; fi
  fi
  sleep 2
done
ssh_ 'echo "== identity"; grep ^ID= /proc/1/root/etc/os-release; test -f /etc/mibox-persistent-root && echo IN_ALPINE_TREE
echo "== kernel and boot source"; cat /proc/version; cat /proc/cmdline
echo "== state"; cat /proc/1/root/run/mibox-alpine-integrity /proc/1/root/run/mibox-time-state /proc/1/root/run/mibox-alpine-ready
echo "== kmsg"; dmesg | grep -e "mibox-" -e "EXT4-fs (mmcblk0p11)" -e "Kernel command line"
echo "== mounts"; grep -e " / " -e mibox-data /proc/1/mountinfo
echo "== host key"; cut -d" " -f1,2 /etc/dropbear/dropbear_ed25519_host_key.pub
echo "== sentinel"; cat /root/slim-physical-sentinel; echo "SLIM_PHYSICAL_$(cat /proc/sys/kernel/random/boot_id)" >> /root/slim-physical-sentinel; sync
echo "== ssh listener parent"; for p in /proc/[0-9]*; do [ "$(cat $p/comm 2>/dev/null)" = dropbear ] && echo "$(basename $p) ppid=$(awk "/^PPid:/{print \$2}" $p/status)"; done; true' 2>&1 | tee -a $ev/watch.txt
echo C5_WATCH_DONE | tee -a $ev/watch.txt
