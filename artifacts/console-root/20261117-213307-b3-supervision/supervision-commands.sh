set -eu
repo=$(wslpath -u "F:/coding/otherPrj/mibox"); cd "$repo"
keysrc=$(wslpath -u "$(cmd.exe /c echo %USERPROFILE% 2>/dev/null | tr -d '\r')")/.ssh/mibox-console
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT; cp "$keysrc" $tmp/key; chmod 600 $tmp/key
ev=$(ls -d artifacts/console-root/*-b3-supervision | tail -1)
ssh_() { ssh -i $tmp/key -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$ev/known_hosts -o ConnectTimeout=5 root@192.168.1.222 "$@"; }
listener='for p in /proc/[0-9]*; do [ "$(cat $p/comm 2>/dev/null)" = dropbear ] && [ "$(awk "/^PPid:/{print \$2}" $p/status)" = 1 ] && echo ${p#/proc/}; done; true'
before=$(ssh_ "$listener"); echo "listener before: $before"
ssh_ "kill -TERM $before && echo KILLED"
for i in $(seq 1 20); do sleep 2; if out=$(ssh_ 'echo BACK' 2>/dev/null); then echo "reconnected after ~$((i*2)) s: $out"; break; fi; done
after=$(ssh_ "$listener"); echo "listener after: $after"
[ -n "$after" ] && [ "$after" != "$before" ] && echo SUPERVISION_RESTART_OK
