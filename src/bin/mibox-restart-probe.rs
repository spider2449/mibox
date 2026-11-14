//! QEMU-only integration probe; excluded from hardware rootfs packaging.
use std::{
    fs,
    io::{self, Read, Write},
    os::unix::{net::UnixStream, process::CommandExt},
    process::Command,
    time::Duration,
};

fn rejected(payload: &[u8]) -> io::Result<()> {
    let mut stream = UnixStream::connect("/dev/mibox-control")?;
    stream.set_read_timeout(Some(Duration::from_secs(4)))?;
    // A denied UID can be disconnected before sending.
    let _ = stream.write_all(payload);
    let _ = stream.shutdown(std::net::Shutdown::Write);
    let mut response = [0; 257];
    match stream.read(&mut response) {
        Ok(0) => Ok(()),
        Err(e) if e.kind() == io::ErrorKind::ConnectionReset => Ok(()),
        _ => Err(io::Error::other(
            "request was not rejected with a closed connection",
        )),
    }
}

fn main() -> io::Result<()> {
    let cmdline = fs::read_to_string("/proc/cmdline")?;
    let guard = cmdline
        .split_whitespace()
        .any(|v| v == "mibox.test_restart_guard=1");
    if !fs::read("/proc/device-tree/compatible")?
        .split(|b| *b == 0)
        .any(|v| v == b"linux,dummy-virt")
        || (!guard
            && !cmdline
                .split_whitespace()
                .any(|v| v == "mibox.test_restart=1"))
    {
        return Err(io::Error::other("QEMU-only probe refused"));
    }
    if std::env::args().nth(1).as_deref() == Some("--denied-uid") {
        rejected(b"CHECK\n")?;
        return rejected(
            format!(
                "HARDWARE capture {}\n",
                fs::read_to_string("/proc/sys/kernel/random/boot_id")?.trim()
            )
            .as_bytes(),
        );
    }
    if guard {
        rejected(b"CHECK\n")?;
        rejected(
            format!(
                "HARDWARE capture {}\n",
                fs::read_to_string("/proc/sys/kernel/random/boot_id")?.trim()
            )
            .as_bytes(),
        )?;
        rejected(
            format!(
                "RESTART {}\n",
                fs::read_to_string("/proc/sys/kernel/random/boot_id")?.trim()
            )
            .as_bytes(),
        )?;
        println!("MIBOX_QEMU_RESTART_PLATFORM_GUARD_OK");
        return Ok(());
    }
    let check = || -> io::Result<()> {
        let result = Command::new("/bin/mibox")
            .args(["reboot-android", "--check"])
            .uid(2000)
            .gid(2000)
            .output()?;
        if !result.status.success()
            || !String::from_utf8_lossy(&result.stdout).starts_with("MIBOX_RESTART_READY boot_id=")
        {
            return Err(io::Error::other(format!(
                "UID2000 check failed: {:?}",
                result
            )));
        }
        Ok(())
    };
    check()?;
    let denied = Command::new(std::env::current_exe()?)
        .arg("--denied-uid")
        .uid(65534)
        .gid(65534)
        .status()?;
    if !denied.success() {
        return Err(io::Error::other("UID65534 denial failed"));
    }
    rejected(b"RESTART 00000000-0000-0000-0000-000000000000\n")?;
    rejected(b"HARDWARE network 00000000-0000-0000-0000-000000000000\n")?;
    rejected(b"HARDWARE capture 00000000-0000-0000-0000-000000000000\n")?;
    rejected(
        format!(
            "HARDWARE shell {}\n",
            fs::read_to_string("/proc/sys/kernel/random/boot_id")?.trim()
        )
        .as_bytes(),
    )?;
    rejected(b"CHECK\nEXTRA\n")?;
    rejected(&[b'x'; 129])?;
    // A peer that never sends EOF must not hold the server indefinitely.
    let mut stalled = UnixStream::connect("/dev/mibox-control")?;
    stalled.set_read_timeout(Some(Duration::from_secs(4)))?;
    let mut byte = [0];
    if stalled.read(&mut byte)? != 0 {
        return Err(io::Error::other("stalled peer not closed"));
    }
    let stale = Command::new("/bin/mibox")
        .args(["reboot-android", "--boot-id", "stale"])
        .uid(2000)
        .gid(2000)
        .output()?;
    if stale.status.success() {
        return Err(io::Error::other("client accepted stale boot ID"));
    }
    check()?;
    println!("MIBOX_QEMU_RESTART_CHECKS_OK uid2000=ready uid65534=denied stale=denied malformed=denied oversized=denied stalled=closed listener=alive");
    io::stdout().flush()?;
    let boot_id = fs::read_to_string("/proc/sys/kernel/random/boot_id")?;
    let result = Command::new("/bin/mibox")
        .args(["reboot-android", "--boot-id", boot_id.trim()])
        .uid(2000)
        .gid(2000)
        .status()?;
    Err(io::Error::other(format!(
        "guest did not restart before client returned: {result}"
    )))
}
