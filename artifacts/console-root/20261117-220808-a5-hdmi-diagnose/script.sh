echo "== display mode"; cat /sys/class/display/mode 2>&1
echo "== hdmitx"; for f in disp_mode hpd_state config; do echo "$f: $(cat /sys/class/amhdmitx/amhdmitx0/$f 2>&1 | head -3)"; done
echo "== fb0"; cat /sys/class/graphics/fb0/blank /sys/class/graphics/fb0/virtual_size /sys/class/graphics/fb0/bits_per_pixel 2>&1
echo "== handoff (manual)"; chroot /proc/1/root /sbin/mibox-fbhandoff; echo rc=$?
echo "== kernel display messages"; dmesg | grep -i -e hdmi -e "osd" -e "vout" | tail -12
