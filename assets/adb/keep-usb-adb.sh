
# BEGIN MIBOX KEEP USB ADB v3
# Observe late startup resets; use SettingsProvider so USB Manager owns USB.
{
    echo MIBOX_ADB_HOOK_BEGIN
    /system/bin/cat /proc/sys/kernel/random/boot_id
    tick=0
    while [ "$tick" -lt 60 ]; do
        saved=$(/system/bin/settings get global adb_enabled)
        echo "TICK=$tick saved=$saved"
        /system/bin/cat /proc/uptime
        /system/bin/getprop sys.usb.config
        /system/bin/getprop sys.usb.state
        /system/bin/getprop init.svc.adbd
        if [ "$saved" = 0 ]; then
            echo MIBOX_ADB_RESTORE_SETTING
            /system/bin/settings put global adb_enabled 1
        fi
        tick=$((tick + 1))
        /system/bin/sleep 2
    done
    /system/bin/settings get global adb_enabled
    echo MIBOX_ADB_HOOK_DONE
} >> /data/local/tmp/mibox-adb-boot.log 2>&1
/system/bin/chmod 0644 /data/local/tmp/mibox-adb-boot.log
# END MIBOX KEEP USB ADB v3
