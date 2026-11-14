//! Fixed rootfs test: no mounts, devices, firmware writes or Android changes.
use std::{
    fs, io,
    os::unix::{fs::PermissionsExt, net::UnixDatagram, process::CommandExt},
    process::Command,
    thread,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

const EXE: &str = "/data/local/tmp/mibox-userspace-test";
const USERLAND: &[u8] = include_bytes!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/target/armv7-unknown-linux-musleabihf/release/mibox-userland"
));
unsafe extern "C" {
    fn geteuid() -> u32;
    fn chroot(path: *const std::os::raw::c_char) -> i32;
    fn chdir(path: *const std::os::raw::c_char) -> i32;
    fn setgroups(count: usize, groups: *const u32) -> i32;
    fn setgid(gid: u32) -> i32;
    fn setuid(uid: u32) -> i32;
}

fn worker(job: &str) -> io::Result<()> {
    if unsafe { geteuid() } != 0 {
        return Err(io::Error::other("root worker required"));
    }
    let base = format!("/data/local/tmp/mibox-userland-{job}");
    fs::create_dir(&base)?; // Reject any existing path, including symlinks.
    fs::set_permissions(&base, fs::Permissions::from_mode(0o755))?;
    let root = format!("{base}/rootfs");
    fs::create_dir(&root)?;
    fs::set_permissions(&root, fs::Permissions::from_mode(0o755))?;
    for directory in ["bin", "etc", "tmp"] {
        let path = format!("{root}/{directory}");
        fs::create_dir(&path)?;
        fs::set_permissions(
            path,
            fs::Permissions::from_mode(if directory == "tmp" { 0o1777 } else { 0o755 }),
        )?;
    }
    let binary = format!("{root}/bin/mibox");
    fs::write(&binary, USERLAND)?;
    fs::set_permissions(&binary, fs::Permissions::from_mode(0o555))?;
    let identity = format!("{root}/etc/os-release");
    fs::write(&identity, include_bytes!("../../assets/rootfs/os-release"))?;
    fs::set_permissions(identity, fs::Permissions::from_mode(0o444))?;
    let mut log = String::from("scope=chroot process, not independent boot or PID1\n");
    for args in [
        &["info"][..],
        &["ls", "/"],
        &["cat", "/etc/os-release"],
        &["selftest"],
    ] {
        let mut command = Command::new("/bin/mibox");
        command.args(args).current_dir(&root);
        // Child only: remove supplementary groups and root before custom code runs.
        unsafe {
            command.pre_exec(|| {
                if chroot(c".".as_ptr()) != 0
                    || chdir(c"/".as_ptr()) != 0
                    || setgroups(0, std::ptr::null()) != 0
                    || setgid(65534) != 0
                    || setuid(65534) != 0
                {
                    return Err(io::Error::last_os_error());
                }
                Ok(())
            });
        }
        let result = command.output()?;
        log.push_str(&format!(
            "COMMAND {args:?} exit={:?}\n{}{}",
            result.status.code(),
            String::from_utf8_lossy(&result.stdout),
            String::from_utf8_lossy(&result.stderr)
        ));
        fs::write(format!("{base}/transcript.txt"), &log)?;
        fs::set_permissions(
            format!("{base}/transcript.txt"),
            fs::Permissions::from_mode(0o644),
        )?;
        if !result.status.success() {
            return Err(io::Error::other(format!(
                "custom userspace failed: {args:?}; see {base}/transcript.txt"
            )));
        }
    }
    fs::write(
        format!("{base}/transcript.txt"),
        format!("{log}MIBOX_USERSPACE_DEVICE_TEST_OK\n"),
    )?;
    Ok(())
}

fn launch() -> io::Result<()> {
    let job = format!(
        "{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(io::Error::other)?
            .as_millis()
    );
    let client = format!("/data/local/tmp/mibox-userspace-{job}.sock");
    let socket = UnixDatagram::bind(&client)?;
    socket.set_read_timeout(Some(Duration::from_secs(3)))?;
    let packet = format!(
        "{}\t1\tpppd pty >/dev/null 2>&1; {EXE} --worker {job}\0",
        std::process::id()
    );
    socket.send_to(packet.as_bytes(), "/dev/socket/pppoe_wrapper")?;
    let mut ack = [0u8; 128];
    let received = socket.recv(&mut ack);
    fs::remove_file(client)?;
    received?;
    let path = format!("/data/local/tmp/mibox-userspace-result-{job}.txt");
    for _ in 0..300 {
        if let Ok(result) = fs::read_to_string(&path) {
            println!("{}", result.trim());
            return if result.starts_with("MIBOX_USERSPACE_WORKER_OK") {
                Ok(())
            } else {
                Err(io::Error::other("userspace worker failed"))
            };
        }
        thread::sleep(Duration::from_millis(100));
    }
    Err(io::Error::new(
        io::ErrorKind::TimedOut,
        "userspace worker timed out",
    ))
}

fn main() -> io::Result<()> {
    let args: Vec<_> = std::env::args().skip(1).collect();
    match args.as_slice() {
        [] => launch(),
        [mode, job]
            if mode == "--worker"
                && !job.is_empty()
                && job.len() < 64
                && job.bytes().all(|b| b.is_ascii_digit() || b == b'-') =>
        {
            let result = worker(job);
            let text = match &result {
                Ok(()) => format!("MIBOX_USERSPACE_WORKER_OK rootfs=/data/local/tmp/mibox-userland-{job}/rootfs\n"),
                Err(error) => format!("MIBOX_USERSPACE_WORKER_ERROR {error}\n"),
            };
            let path = format!("/data/local/tmp/mibox-userspace-result-{job}.txt");
            fs::write(&path, text)?;
            fs::set_permissions(path, fs::Permissions::from_mode(0o644))?;
            result
        }
        _ => Err(io::Error::other("unsupported arguments")),
    }
}
