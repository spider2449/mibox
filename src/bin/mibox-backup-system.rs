//! Bounded read-only system partition backup in 64 MiB chunks.
use std::os::unix::fs::{FileTypeExt, MetadataExt};
use std::{
    fs, io,
    os::unix::net::UnixDatagram,
    thread,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

fn main() -> io::Result<()> {
    let args: Vec<_> = std::env::args().skip(1).collect();
    if args.len() != 2 || !matches!(args[0].as_str(), "system" | "system1") {
        return Err(io::Error::other(
            "usage: mibox-backup-system system|system1 0..7|hash",
        ));
    }
    let name = &args[0];
    let index = if args[1] == "hash" {
        None
    } else {
        Some(args[1].parse::<u32>().map_err(io::Error::other)?)
    };
    if index.is_some_and(|value| value > 7) {
        return Err(io::Error::other("chunk outside partition"));
    }
    if fs::read_to_string(format!("/sys/class/block/{name}/size"))?.trim() != "1048576" {
        return Err(io::Error::other("expected a 512 MiB partition"));
    }
    let metadata = fs::metadata(format!("/dev/block/{name}"))?;
    if !metadata.file_type().is_block_device() {
        return Err(io::Error::other("source is not a block device"));
    }
    let readonly = fs::read_to_string(format!("/sys/class/block/{name}/ro"))?;
    if readonly.trim() != "1" {
        // An inactive, unmounted source can be read without changing block flags.
        // Compare device numbers as well as paths, so aliases cannot hide mounts.
        for mount in fs::read_to_string("/proc/mounts")?.lines() {
            let source = mount.split_whitespace().next().unwrap_or("");
            if source.starts_with("/dev/block/") && fs::metadata(source)?.rdev() == metadata.rdev()
            {
                return Err(io::Error::other(
                    "source mounted without block read-only protection",
                ));
            }
        }
    }
    let job = format!(
        "{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(io::Error::other)?
            .as_millis()
    );
    let directory = format!("/data/local/tmp/mibox-system-chunk-{job}");
    fs::create_dir(&directory)?;
    let image = format!("{directory}/chunk.img");
    let digest = format!("{directory}/digest.txt");
    let done = format!("{directory}/done");
    let command = if let Some(index) = index {
        format!("/system/xbin/busybox dd if=/dev/block/{name} of=chunk.img bs=4096 skip={} count=16384 2>dd.log && chmod 644 chunk.img && /system/xbin/busybox sha256sum chunk.img >digest.txt", index * 16384)
    } else {
        format!("/system/xbin/busybox sha256sum /dev/block/{name} >digest.txt")
    };
    let command = format!("cd {directory} && {command} && chmod 644 digest.txt && echo complete >done && chmod 644 done");
    let client = format!("{directory}/client.sock");
    let socket = UnixDatagram::bind(&client)?;
    socket.set_read_timeout(Some(Duration::from_secs(3)))?;
    let packet = format!(
        "{}\t1\tpppd pty >/dev/null 2>&1; {command}\0",
        std::process::id()
    );
    if packet.len() > 511 {
        return Err(io::Error::other("request exceeds daemon limit"));
    }
    socket.send_to(packet.as_bytes(), "/dev/socket/pppoe_wrapper")?;
    let mut ack = [0u8; 128];
    let received = socket.recv(&mut ack);
    fs::remove_file(client)?;
    received?;
    for _ in 0..1200 {
        if fs::read_to_string(&done).is_ok_and(|value| value.trim() == "complete") {
            let checksum = fs::read_to_string(&digest)?;
            let hash = checksum.split_whitespace().next().unwrap_or("");
            if hash.len() != 64 || !hash.bytes().all(|b| b.is_ascii_hexdigit()) {
                return Err(io::Error::other("invalid digest"));
            }
            if index.is_some() && fs::metadata(&image)?.len() != 67108864 {
                return Err(io::Error::other("incomplete chunk"));
            }
            println!("DIRECTORY={directory}\nSHA256={hash}");
            if index.is_some() {
                println!("CHUNK_PATH={image}");
            }
            println!("MIBOX_SYSTEM_BACKUP_READ_OK");
            return Ok(());
        }
        thread::sleep(Duration::from_millis(100));
    }
    Err(io::Error::new(
        io::ErrorKind::TimedOut,
        format!("read did not complete; preserve {directory}"),
    ))
}
