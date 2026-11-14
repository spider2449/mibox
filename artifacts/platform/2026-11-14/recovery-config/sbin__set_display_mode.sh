#!/system/bin/sh
#for recovery
hpdstate=$(cat /sys/class/amhdmitx/amhdmitx0/hpd_state)
old_state=$hpdstate

busybox echo 1 > /sys/class/graphics/fb0/blank
busybox echo 1 > /sys/class/graphics/fb1/blank

if [ $hpdstate -eq 0 ] ; then
    busybox echo 576cvbs > /sys/class/display/mode
    busybox echo 30 20 680 556 0 > /sys/class/ppmgr/ppscaler_rect
else
    busybox echo 720p > /sys/class/display/mode
    busybox echo 40 25 1240 690 0 > /sys/class/ppmgr/ppscaler_rect
fi

echo 0 0 1280 720 0 0 18 18 > /sys/class/display/axis
echo 0 > /sys/class/graphics/fb0/freescale_mode
echo 0 > /sys/class/graphics/fb1/freescale_mode
echo 0 0 1279 719 > /sys/class/graphics/fb0/free_scale_axis
busybox echo 0x10001 > /sys/class/graphics/fb0/free_scale

#for checking is hdmi or cvbs

while true ; do
hpdstate=$(cat /sys/class/amhdmitx/amhdmitx0/hpd_state)

if [ $hpdstate != $old_state ] ; then
	old_state=$hpdstate
        if [ $hpdstate -eq 0 ] ; then
	    busybox echo 576cvbs > /sys/class/display/mode
	    busybox echo 30 20 680 556 0 > /sys/class/ppmgr/ppscaler_rect
	    busybox echo vdac > /sys/class/aml_mod/mod_on
	else
	    busybox echo 720p > /sys/class/display/mode
	    busybox echo 40 25 1240 690 0 > /sys/class/ppmgr/ppscaler_rect
	    busybox echo vdac > /sys/class/aml_mod/mod_off
	fi
	echo 0 0 1280 720 0 0 18 18 > /sys/class/display/axis
	echo 0 > /sys/class/graphics/fb0/freescale_mode
	echo 0 > /sys/class/graphics/fb1/freescale_mode
	echo 0 0 1279 719 > /sys/class/graphics/fb0/free_scale_axis
	busybox echo 0x10001 > /sys/class/graphics/fb0/free_scale
	busybox echo 0 > /sys/class/graphics/fb0/blank
fi

sleep 1

done
