#!/sbin/sh

busybox mount -t ext4 -o ro /dev/block/backup /backup

busybox mount -t ext4 /dev/block/system /system
busybox rm -rf /system/*
busybox cp -Rpf /backup/* /system

busybox umount /system
busybox umount /backup

