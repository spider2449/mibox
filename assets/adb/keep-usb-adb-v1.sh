
# BEGIN MIBOX KEEP USB ADB v1
# Restore the owner's USB debugging choice after stock Settings initialization.
{
    echo MIBOX_ADB_HOOK_BEGIN
    /system/bin/cat /proc/sys/kernel/random/boot_id
    /system/bin/sleep 20
    /system/bin/settings put global adb_enabled 1
    /system/bin/setprop persist.sys.usb.config adb
    /system/bin/settings get global adb_enabled
    /system/bin/getprop persist.sys.usb.config
    echo MIBOX_ADB_HOOK_DONE
} >> /data/local/tmp/mibox-adb-boot.log 2>&1
/system/bin/chmod 0644 /data/local/tmp/mibox-adb-boot.log
# END MIBOX KEEP USB ADB v1
