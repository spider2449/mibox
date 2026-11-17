echo "== rtc"; hwclock -r -u 2>&1; cat /sys/class/rtc/rtc0/since_epoch 2>&1
echo "== system before"; date -u
echo "== ntp"; timeout 30 busybox ntpd -n -q -p pool.ntp.org 2>&1; echo rc=$?
echo "== system after"; date -u
echo "== apk hooks dir"; ls -la /etc/apk/commit_hooks.d 2>&1
