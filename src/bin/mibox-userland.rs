//! Self-contained custom ARMv7 userspace; requires no Android executables/libs.
use std::io::{Read, Write};
use std::{fs, io, process::Command};
#[path = "../ram_control.rs"]
#[allow(dead_code)]
mod ram_control;
#[path = "../runtime_health.rs"]
mod runtime_health;

unsafe extern "C" {
    fn getuid() -> u32;
    fn geteuid() -> u32;
    fn getgid() -> u32;
    fn getegid() -> u32;
    fn uname(buffer: *mut u8) -> i32;
}

fn uts_fields() -> io::Result<Vec<String>> {
    let mut uts = [0u8; 390];
    if unsafe { uname(uts.as_mut_ptr()) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(uts
        .chunks_exact(65)
        .map(|field| String::from_utf8_lossy(field.split(|b| *b == 0).next().unwrap()).into_owned())
        .collect())
}

fn ram_selftest() -> io::Result<()> {
    let uid = unsafe { getuid() };
    if uid == 0 || uid != unsafe { geteuid() } {
        return Err(io::Error::other(
            "RAM self-test requires an unprivileged user",
        ));
    }
    if !fs::read_to_string("/etc/os-release")?
        .lines()
        .any(|s| s == "ID=mibox-custom")
    {
        return Err(io::Error::other("custom rootfs required"));
    }
    // Establish that /tmp is RAM-backed before creating the test directory.
    let mounts = fs::read_to_string("/proc/mounts")?;
    let mut root_ram = false;
    for line in mounts.lines() {
        let fields: Vec<_> = line.split_whitespace().collect();
        if fields.len() < 3 {
            return Err(io::Error::other("invalid mount table"));
        }
        if fields[1] == "/" {
            root_ram = matches!(fields[2], "rootfs" | "ramfs" | "tmpfs");
        }
        if fields[1] == "/tmp" || fields[1].starts_with("/tmp/") {
            return Err(io::Error::other(
                "separate /tmp mount: RAM status not established",
            ));
        }
    }
    if !root_ram || fs::symlink_metadata("/tmp")?.file_type().is_symlink() {
        return Err(io::Error::other("RAM-backed /tmp required"));
    }
    let directory = format!("/tmp/mibox-ram-selftest-{}", std::process::id());
    fs::create_dir(&directory)?;
    let path = format!("{directory}/payload");
    let result = (|| {
        let payload: Vec<u8> = (0..65536).map(|i| ((i * 31 + 7) & 255) as u8).collect();
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&path)?;
        file.write_all(&payload)?;
        drop(file);
        let mut actual = Vec::new();
        fs::File::open(&path)?.read_to_end(&mut actual)?;
        if actual != payload {
            return Err(io::Error::other("RAM file readback mismatch"));
        }
        let status = Command::new(std::env::current_exe()?)
            .arg("--child-probe")
            .status()?;
        if status.code() != Some(17) {
            return Err(io::Error::other("child exit status mismatch"));
        }
        println!(
            "MIBOX_RAM_SELFTEST_OK uid={uid} bytes={} file_io=ok child_exit=17",
            payload.len()
        );
        Ok(())
    })();
    // Only remove the exact file and directory created by this invocation.
    let _ = fs::remove_file(&path);
    let cleanup = fs::remove_dir(&directory);
    result.and(cleanup)
}

fn main() -> io::Result<()> {
    let args: Vec<_> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str).unwrap_or("info") {
        "hardware-test" => {
            if args.len() != 4 || args[2] != "--boot-id" {
                return Err(io::Error::other("usage: hardware-test network|display|audio|capture --boot-id CURRENT_BOOT_ID"));
            }
            ram_control::hardware_request(&args[1], &args[3])?;
        }
        "reboot-android" => {
            match args.get(1).map(String::as_str) {
                Some("--check") if args.len() == 2 => ram_control::request(None)?,
                Some("--boot-id") if args.len() == 3 => ram_control::request(Some(&args[2]))?,
                _ => return Err(io::Error::other("usage: reboot-android --check | reboot-android --boot-id CURRENT_BOOT_ID")),
            }
        }
        "reboot-loader" => {
            match args.get(1).map(String::as_str) {
                Some("--boot-id") if args.len() == 3 => ram_control::request_loader(&args[2])?,
                _ => return Err(io::Error::other("usage: reboot-loader --boot-id CURRENT_BOOT_ID")),
            }
        }
        "--child-probe" => std::process::exit(17),
        "uname" => {
            let fields = uts_fields()?;
            println!("{} {} {} {} {}", fields[0], fields[1], fields[2], fields[3], fields[4]);
        }
        "id" => println!("uid={} euid={} gid={} egid={}", unsafe {getuid()}, unsafe {geteuid()}, unsafe {getgid()}, unsafe {getegid()}),
        "uptime" => print!("{}", fs::read_to_string("/proc/uptime")?),
        "mounts" => print!("{}", fs::read_to_string("/proc/mounts")?),
        "ps" => {
            let mut pids: Vec<u32> = fs::read_dir("/proc")?.filter_map(|entry| entry.ok()?.file_name().to_str()?.parse().ok()).collect();
            pids.sort_unstable();
            println!("PID\tPPID\tUID\tSTATE\tNAME");
            for pid in pids {
                let Ok(status) = fs::read_to_string(format!("/proc/{pid}/status")) else {continue};
                let value = |key: &str| status.lines().find_map(|s| s.strip_prefix(key)).unwrap_or("UNKNOWN").trim();
                println!("{pid}\t{}\t{}\t{}\t{}", value("PPid:"), value("Uid:").split_whitespace().next().unwrap_or("UNKNOWN"), value("State:"), value("Name:"));
            }
        }
        "net" => {
            let mut interfaces = fs::read_dir("/sys/class/net")?.collect::<io::Result<Vec<_>>>()?;
            interfaces.sort_by_key(|entry| entry.file_name());
            println!("INTERFACE\tSTATE\tCARRIER\tMAC");
            for interface in interfaces {
                let attr = |name| fs::read_to_string(interface.path().join(name)).map(|s| s.trim().to_owned()).unwrap_or_else(|_| "UNKNOWN".into());
                println!("{}\t{}\t{}\t{}", interface.file_name().to_string_lossy(), attr("operstate"), attr("carrier"), attr("address"));
            }
            print!("IPv4 route table:\n{}", fs::read_to_string("/proc/net/route")?);
        }
        "ram-selftest" => ram_selftest()?,
        "health" => print!("{}", runtime_health::snapshot()),
        "info" => {
            print!("{}", fs::read_to_string("/etc/os-release")?);
            let fields = uts_fields()?;
            println!(
                "kernel={} pid={} uid={} euid={}",
                fields[2],
                std::process::id(),
                unsafe { getuid() },
                unsafe { geteuid() }
            );
        }
        "ls" => {
            let path = args.get(1).map(String::as_str).unwrap_or("/");
            let mut names = fs::read_dir(path)?
                .map(|entry| entry.map(|v| v.file_name()))
                .collect::<io::Result<Vec<_>>>()?;
            names.sort();
            for name in names {
                println!("{}", name.to_string_lossy());
            }
        }
        "cat" => {
            let path = args
                .get(1)
                .ok_or_else(|| io::Error::other("cat requires a path"))?;
            print!("{}", fs::read_to_string(path)?);
        }
        "selftest" => {
            if unsafe { getuid() } != 65534 || unsafe { geteuid() } != 65534 {
                return Err(io::Error::other(
                    "selftest must run as unprivileged chroot user",
                ));
            }
            let os = fs::read_to_string("/etc/os-release")?;
            if !os.contains("ID=mibox-custom") {
                return Err(io::Error::other("unexpected rootfs"));
            }
            if fs::metadata("/system").is_ok() || fs::metadata("/data").is_ok() {
                return Err(io::Error::other("Android paths visible in test root"));
            }
            let path = format!("/tmp/probe-{}", std::process::id());
            fs::write(&path, b"MIBOX_CUSTOM_USERSPACE\n")?;
            if fs::read(&path)? != b"MIBOX_CUSTOM_USERSPACE\n" {
                return Err(io::Error::other("file readback mismatch"));
            }
            fs::remove_file(path)?;
            if fs::OpenOptions::new()
                .write(true)
                .open("/etc/os-release")
                .is_ok()
            {
                return Err(io::Error::other(
                    "unprivileged user can modify rootfs config",
                ));
            }
            let child = Command::new("/bin/mibox").arg("--child-probe").status()?;
            if child.code() != Some(17) {
                return Err(io::Error::other("child exit status mismatch"));
            }
            println!("MIBOX_USERSPACE_SELFTEST_OK rootfs=custom uid=65534 file_io=ok child_exec=ok android_paths=absent");
        }
        _ => {
            return Err(io::Error::other(
                "commands: info, health, uname, id, uptime, mounts, ps, net, ls [path], cat path, ram-selftest, selftest, reboot-android --check | --boot-id CURRENT_BOOT_ID, reboot-loader --boot-id CURRENT_BOOT_ID",
            ))
        }
    }
    Ok(())
}
