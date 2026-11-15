#!/bin/sh
# Run from PID1's RAM root. No credentials in this script or saved logs.
set -eu
base=/tmp/mibox-wifi-tools
loader=$base/lib/ld-musl-armhf.so.1
libs=$base/usr/lib:$base/lib
wpa() { "$loader" --library-path "$libs" "$base/sbin/wpa_supplicant" "$@"; }
cli() { "$loader" --library-path "$libs" "$base/sbin/wpa_cli" -p "$base/ctrl" -i wlan0 "$@"; }
cleanup() {
    if [ -f "$base/wpa.pid" ]; then kill "$(cat "$base/wpa.pid")" 2>/dev/null || :; fi
    ip rule del priority 19300 2>/dev/null || :
    ip route flush table 193 2>/dev/null || :
    ip addr flush dev wlan0
    ip link set wlan0 down
    rm -f "$base/test.conf" "$base/wpa.pid"
    echo CLEANUP_DONE
    ip route
}
trap cleanup EXIT
trap 'exit 124' TERM INT
test "$(cat /proc/sys/kernel/osrelease)" = 3.10.33
test -f "$base/test.conf"
echo BOOT_ID=$(cat /proc/sys/kernel/random/boot_id)
ip route
ip link set wlan0 up
wpa -B -i wlan0 -D nl80211 -c "$base/test.conf" -P "$base/wpa.pid" > "$base/wpa.log" 2>&1
connected=0
for attempt in $(seq 1 25); do
    status=$(cli status 2>/dev/null || :)
    if echo "$status" | grep -q '^wpa_state=COMPLETED$'; then connected=1; break; fi
    sleep 1
done
echo "$status"
if [ "$connected" != 1 ]; then
    echo ASSOCIATION_FAILED
    tail -20 "$base/wpa.log"
    exit 1
fi
echo ASSOCIATION_PASS
address=192.168.1.223
gateway=192.168.1.1
arping -D -I wlan0 -c 3 -w 4 "$address" || { echo ADDRESS_CONFLICT; exit 1; }
echo ADDRESS_PROBE_NO_REPLY
ip addr add "$address/24" dev wlan0
ip route add 192.168.1.0/24 dev wlan0 src "$address" table 193
ip route add default via "$gateway" dev wlan0 table 193
ip rule add priority 19300 from "$address/32" table 193
echo STATIC_IP_CONFIGURED

ip addr show wlan0
ip route show table 193
ip route get 1.1.1.1 from "$address"
ping -I "$address" -c 3 -W 2 "$gateway" && echo WIFI_GATEWAY_PASS
if ping -I "$address" -c 3 -W 2 1.1.1.1; then echo WIFI_EXTERNAL_ICMP_PASS; else echo WIFI_EXTERNAL_ICMP_FAILED; fi
cli status
