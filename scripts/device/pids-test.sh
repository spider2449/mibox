#!/bin/sh
# On-box test of the backported pids cgroup controller (kernel patch 0003),
# run in the Alpine tree over SSH after mibox-docker has mounted the cgroup
# v1 hierarchies. Prints one "PASS name" or "FAIL name detail" line per
# check and "PIDS_TEST passed=N failed=M" at the end. Uses its own cgroups
# (mibox-pids-test*) and a short-lived container, removed at the end.
set -u
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
cg=/sys/fs/cgroup/pids
t=$cg/mibox-pids-test
pass=0; fail=0
ok() { echo "PASS $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1 ${2:-}"; fail=$((fail + 1)); }
check() { name=$1; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }
cur() { cat "$1/pids.current"; }
cleanup() {
    for d in "$t/child" "$t" "$cg/mibox-pids-test2"; do
        [ -d "$d" ] || continue
        for p in $(cat "$d/cgroup.procs" 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
    done
    sleep 1
    rmdir "$t/child" "$t" "$cg/mibox-pids-test2" 2>/dev/null
    docker rm -f mibox-pids-bomb > /dev/null 2>&1
}
cleanup

echo "== interface"
check proc-cgroups-lists-pids grep -q '^pids[[:space:]].*[[:space:]]1$' /proc/cgroups
check hierarchy-mounted grep -q " $cg cgroup .*pids" /proc/self/mountinfo
check root-has-no-max test ! -e "$cg/pids.max"
mkdir "$t"
check new-max-is-max test "$(cat "$t/pids.max")" = max
check new-current-is-0 test "$(cur "$t")" = 0
for v in -1 abc 32769; do
    if echo "$v" > "$t/pids.max" 2>/dev/null; then bad "reject-$v"; else ok "reject-$v"; fi
done
check accept-32768 sh -c "echo 32768 > $t/pids.max && test \$(cat $t/pids.max) = 32768"
check accept-max sh -c "echo max > $t/pids.max && test \$(cat $t/pids.max) = max"

echo "== fork limit"
echo 3 > "$t/pids.max"
# A shell joins the cgroup (1 task) and starts 4 background sleeps: two fit
# under the limit of 3, the other two must fail with EAGAIN.
sh -c "echo \$\$ > $t/cgroup.procs; for i in 1 2 3 4; do sleep 30 & done; wait" > /tmp/pids-fork.out 2>&1 &
sleep 2
check limit-current-is-3 test "$(cur "$t")" = 3
nfail=$(grep -c -i "can't fork\|resource temporarily unavailable" /tmp/pids-fork.out)
check limit-two-forks-refused test "$nfail" -ge 2
for p in $(cat "$t/cgroup.procs"); do kill -9 "$p"; done; sleep 1
check exit-uncharges test "$(cur "$t")" = 0

echo "== hierarchy"
mkdir "$t/child"; echo 2 > "$t/pids.max"
check child-max-is-max test "$(cat "$t/child/pids.max")" = max
sh -c "echo \$\$ > $t/child/cgroup.procs; for i in 1 2 3; do sleep 30 & done; wait" > /tmp/pids-hier.out 2>&1 &
sleep 2
check parent-limit-binds-child test "$(cur "$t/child")" = 2
check parent-counts-child test "$(cur "$t")" = 2
for p in $(cat "$t/child/cgroup.procs"); do kill -9 "$p"; done; sleep 1
check hierarchy-uncharged test "$(cur "$t")$(cur "$t/child")" = 00

echo "== migration"
echo max > "$t/pids.max"; mkdir "$cg/mibox-pids-test2"
sleep 60 & s=$!
echo "$s" > "$t/cgroup.procs"
check migrate-in-charges test "$(cur "$t")" = 1
echo "$s" > "$cg/mibox-pids-test2/cgroup.procs"
check migrate-across-moves test "$(cur "$t")$(cur "$cg/mibox-pids-test2")" = 01
echo 0 > "$t/pids.max"
echo "$s" > "$t/cgroup.procs"
check migrate-ignores-limit test "$(cur "$t")" = 1
echo "$s" > "$cg/cgroup.procs"
check migrate-to-root-uncharges test "$(cur "$t")$(cur "$cg/mibox-pids-test2")" = 00
kill "$s"; wait "$s" 2>/dev/null

echo "== docker"
docker run --rm --pids-limit 8 alpine:3.22 sh -c 'for i in $(seq 12); do sleep 3 & done; wait' > /tmp/pids-docker.out 2>&1
check docker-no-unsupported-warning sh -c "! grep -qi 'does not support pids' /tmp/pids-docker.out"
check docker-limit-enforced grep -qi "can't fork" /tmp/pids-docker.out
docker run -d --name mibox-pids-bomb --pids-limit 32 alpine:3.22 \
    sh -c 'b() { b | b & }; b; sleep 20' > /dev/null 2>&1
sleep 6
id=$(docker inspect -f '{{.Id}}' mibox-pids-bomb 2>/dev/null)
bc=$(cat "$cg/docker/$id/pids.current" 2>/dev/null || echo missing)
check bomb-capped-at-32 sh -c "[ '$bc' != missing ] && [ $bc -le 32 ]"
check box-still-forks sh -c 'true'
docker rm -f mibox-pids-bomb > /dev/null 2>&1

echo "== kernel log"
check no-accounting-warning sh -c "! dmesg | grep -q 'cgroup_pids'"
cleanup
echo "PIDS_TEST passed=$pass failed=$fail"
