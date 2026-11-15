
set -eu
test -f /etc/mibox-persistent-root
test "$(cat /proc/sys/kernel/osrelease)" = 3.10.33
echo '=== identity ==='
cat /proc/1/root/etc/os-release
cat /proc/sys/kernel/random/boot_id
uname -a
cat /proc/cmdline
echo '=== device tree ==='
for f in model compatible; do
  if test -f /proc/device-tree/$f; then tr '\000' '\n' < /proc/device-tree/$f; fi
done
echo '=== mounts ==='
cat /proc/mounts
cat /proc/self/mountinfo
echo '=== storage ==='
df -Pk / /proc/1/root/tmp
stat -f / /proc/1/root/tmp
readlink -f /root
cat /proc/partitions
cat /sys/class/block/data/dev /sys/class/block/data/size
echo '=== persistent sentinels ==='
sha256sum /usr/bin/less /usr/bin/nano /usr/bin/curl /lib/apk/db/installed /etc/mibox-console-persistence-test
echo '=== memory CPU IO ==='
cat /proc/meminfo /proc/cpuinfo /proc/diskstats
echo '=== routes ==='
ip addr
ip route
ip rule
echo '=== thermal and frequency ==='
for d in /sys/class/thermal/thermal_zone* /sys/class/hwmon/hwmon* /sys/devices/system/cpu/cpu*/cpufreq; do
  test -d "$d" || continue
  echo "PATH=$d"
  for f in "$d"/type "$d"/temp "$d"/name "$d"/temp*_input "$d"/temp*_label "$d"/temp*_crit "$d"/trip_point_* "$d"/scaling_* "$d"/cpuinfo_*; do
    test -f "$f" && test -r "$f" || continue
    echo "FILE=$f"
    cat "$f" || echo READ_FAILED
  done
done
echo '=== USB ==='
for d in /sys/bus/usb/devices/*; do
  test -d "$d" || continue
  echo "PATH=$d"
  for f in idVendor idProduct manufacturer product serial speed busnum devnum bMaxPower; do
    if test -r "$d/$f"; then echo "FILE=$f"; cat "$d/$f"; fi
  done
done
cat /proc/bus/input/devices
echo '=== decoder and output nodes ==='
ls -l /dev/am* /dev/video* /dev/fb* /dev/snd /dev/rtc* /dev/input 2>/dev/null || :
for f in /sys/class/graphics/fb*/virtual_size /sys/class/graphics/fb*/bits_per_pixel /sys/class/graphics/fb*/stride; do
  if test -r "$f"; then echo "FILE=$f"; cat "$f"; fi
done
cat /proc/modules
echo '=== available programs ==='
for program in python3 ffmpeg ffprobe aplay strace timeout sha256sum; do command -v "$program" || :; done
echo '=== suspend inventory; no suspend requested ==='
for f in /sys/power/state /sys/power/wakeup_count /proc/acpi/wakeup /sys/class/rtc/rtc*/name /sys/class/rtc/rtc*/wakealarm /sys/kernel/debug/wakeup_sources; do
  if test -r "$f"; then echo "FILE=$f"; cat "$f" || echo READ_FAILED; fi
done
for f in /sys/devices/platform/*/power/wakeup; do
  if test -r "$f"; then echo "FILE=$f"; cat "$f"; fi
done
echo INVENTORY_COMPLETE
