//! Fixed read-only partition backup via the owner's Mi Box local daemon.
//! Writes scratch backup files only; no block device is opened for writing.
use std::{fs, io, os::unix::net::UnixDatagram, thread, time::Duration};

fn request(command: &str, number: usize) -> io::Result<()> {
    let client = format!(
        "/data/local/tmp/mibox-backup-client-{}-{number}.sock",
        std::process::id()
    );
    let socket = UnixDatagram::bind(&client)?;
    socket.set_read_timeout(Some(Duration::from_secs(3)))?;
    let packet = format!(
        "{}\t{number}\tpppd pty >/dev/null 2>&1; {command}\0",
        std::process::id()
    );
    if packet.len() > 511 {
        return Err(io::Error::other("request too long"));
    }
    socket.send_to(packet.as_bytes(), "/dev/socket/pppoe_wrapper")?;
    let mut ack = [0u8; 128];
    let result = socket.recv(&mut ack);
    fs::remove_file(client)?;
    result.map(|_| ())
}

fn main() -> io::Result<()> {
    let args: Vec<_> = std::env::args().skip(1).collect();
    let emmc_boot = match args.as_slice() {
        [] => false,
        [mode] if mode == "--emmc-boot" => true,
        _ => return Err(io::Error::other("supported option: --emmc-boot")),
    };
    let directory = format!("/data/local/tmp/mibox-boot-backup-{}", std::process::id());
    // Refuse to reuse an existing directory, including symlinks.
    if fs::symlink_metadata(&directory).is_ok() {
        return Err(io::Error::other("backup directory already exists"));
    }
    request(&format!("/system/xbin/busybox mkdir -m 755 {directory}"), 1)?;
    let mut created = false;
    for _ in 0..30 {
        if fs::metadata(&directory).is_ok_and(|entry| entry.is_dir()) {
            created = true;
            break;
        }
        thread::sleep(Duration::from_millis(100));
    }
    if !created {
        return Err(io::Error::other("root backup directory was not created"));
    }
    let original: &[(&str, u64)] = &[
        ("boot", 8388608u64),
        ("boot1", 8388608),
        ("recovery", 8388608),
        ("bootloader", 2097152),
        ("env", 4194304),
        ("reserved", 2097152),
        ("logo", 4194304),
    ];
    let hardware_boot: &[(&str, u64)] = &[("mmcblk0boot0", 2097152), ("mmcblk0boot1", 2097152)];
    let partitions = if emmc_boot { hardware_boot } else { original };
    for (index, (name, expected)) in partitions.iter().enumerate() {
        if emmc_boot
            && fs::read_to_string(format!("/sys/class/block/{name}/size"))?.trim() != "4096"
        {
            return Err(io::Error::other("unexpected eMMC boot region size"));
        }
        let image = format!("{directory}/{name}.img");
        let done = format!("{directory}/{name}.done");
        let command = format!("/system/xbin/busybox dd if=/dev/block/{name} of={image} bs=4096 count={} 2>{directory}/{name}.log && chmod 644 {image} && echo complete >{done} && chmod 644 {done}", expected / 4096);
        request(&command, index + 2)?;
        let mut completed = false;
        for _ in 0..600 {
            if let Ok(marker) = fs::read_to_string(&done) {
                if marker.trim() == "complete" {
                    completed = true;
                    break;
                }
            }
            thread::sleep(Duration::from_millis(100));
        }
        if !completed || fs::metadata(&image)?.len() != *expected {
            return Err(io::Error::other(format!("incomplete backup: {name}")));
        }
        println!("BACKED_UP {name} {expected}");
    }
    println!("BACKUP_DIRECTORY={directory}");
    println!("MIBOX_BOOT_BACKUP_OK");
    Ok(())
}
