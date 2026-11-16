//! Narrow control channel owned by the custom RAM PID1. Never runs a shell.
use std::{
    fs,
    io::{self, Read, Write},
    os::{
        fd::AsRawFd,
        raw::{c_int, c_void},
        unix::{
            fs::PermissionsExt,
            net::{UnixListener, UnixStream},
        },
    },
    time::{Duration, Instant},
};

const SOCKET: &str = "/dev/mibox-control";
const ACCEPTED: &str = "MIBOX_RESTART_ACCEPTED\n";
const LOADER_ACCEPTED: &str = "MIBOX_LOADER_RESTART_ACCEPTED\n";
/// Stock kernel reboot argument that selects reason 0x09090909 (`usb_burning`)
/// in the bootloader; physically proven from Android to expose C003.
#[cfg(feature = "loader-restart")]
const LOADER_REBOOT_ARG: &[u8] = b"usb_burner_reboot\0";
#[cfg(feature = "container-kernel-test")]
#[path = "kernel_development.rs"]
mod kernel_development;

pub fn development_kernel_allowed(release: &str) -> bool {
    #[cfg(feature = "container-kernel-test")]
    {
        fs::read("/etc/mibox-kernel-development")
            .is_ok_and(|marker| kernel_development::accepts(release, &marker))
    }
    #[cfg(not(feature = "container-kernel-test"))]
    {
        let _ = release;
        false
    }
}
#[repr(C)]
struct Credentials {
    pid: c_int,
    uid: u32,
    gid: u32,
}
unsafe extern "C" {
    fn getsockopt(
        fd: c_int,
        level: c_int,
        option: c_int,
        value: *mut c_void,
        length: *mut u32,
    ) -> c_int;
    fn getuid() -> u32;
    fn reboot(command: c_int) -> c_int;
    #[cfg(feature = "loader-restart")]
    fn syscall(number: std::os::raw::c_long, ...) -> std::os::raw::c_long;
}

/// Fallback for a lost preboot window: restart with the USB loader reason.
/// Built only with the `loader-restart` feature; default builds reject LOADER.
/// Returns only if the kernel refused the request.
#[cfg(feature = "loader-restart")]
fn loader_restart() -> io::Error {
    const SYS_REBOOT_ARM: std::os::raw::c_long = 88;
    const LINUX_REBOOT_MAGIC1: c_int = 0xfee1_dead_u32 as c_int;
    const LINUX_REBOOT_MAGIC2: c_int = 672_274_793;
    const LINUX_REBOOT_CMD_RESTART2: c_int = 0xa1b2_c3d4_u32 as c_int;
    unsafe {
        syscall(
            SYS_REBOOT_ARM,
            LINUX_REBOOT_MAGIC1,
            LINUX_REBOOT_MAGIC2,
            LINUX_REBOOT_CMD_RESTART2,
            LOADER_REBOOT_ARG.as_ptr(),
        )
    };
    io::Error::last_os_error()
}

fn credentials(stream: &UnixStream) -> io::Result<Credentials> {
    let mut peer = Credentials {
        pid: 0,
        uid: u32::MAX,
        gid: u32::MAX,
    };
    let mut length = std::mem::size_of::<Credentials>() as u32;
    if unsafe {
        getsockopt(
            stream.as_raw_fd(),
            1,
            17,
            (&mut peer as *mut Credentials).cast(),
            &mut length,
        )
    } != 0
    {
        return Err(io::Error::last_os_error());
    }
    if length as usize != std::mem::size_of::<Credentials>() {
        return Err(io::Error::other("invalid peer credentials"));
    }
    Ok(peer)
}

fn bounded_request(stream: &mut UnixStream) -> io::Result<Vec<u8>> {
    let deadline = Instant::now() + Duration::from_secs(2);
    let mut data = Vec::new();
    loop {
        let remaining = deadline
            .checked_duration_since(Instant::now())
            .ok_or_else(|| io::Error::other("control request deadline"))?;
        stream.set_read_timeout(Some(remaining))?;
        let mut bytes = [0; 129];
        let count = stream.read(&mut bytes)?;
        if count == 0 {
            return Ok(data);
        }
        if data.len() + count > 128 {
            return Err(io::Error::other("control request too long"));
        }
        data.extend_from_slice(&bytes[..count]);
    }
}

fn readiness() -> io::Result<String> {
    if std::process::id() != 1 || unsafe { getuid() } != 0 {
        return Err(io::Error::other("requires root PID1"));
    }
    if !fs::read_to_string("/etc/os-release")?
        .lines()
        .any(|s| s == "ID=mibox-custom")
    {
        return Err(io::Error::other("requires custom OS marker"));
    }
    let mounts = fs::read_to_string("/proc/mounts")?;
    let mut ram_root = false;
    for line in mounts.lines() {
        let fields: Vec<_> = line.split_whitespace().collect();
        if fields.len() < 3 {
            return Err(io::Error::other("invalid mount table"));
        }
        if fields[1] == "/" {
            ram_root = matches!(fields[2], "rootfs" | "ramfs" | "tmpfs");
        }
        if !matches!(
            fields[2],
            "rootfs" | "ramfs" | "tmpfs" | "proc" | "sysfs" | "devtmpfs" | "devpts" | "functionfs"
        ) {
            return Err(io::Error::other("non-RAM/nonvirtual filesystem mounted"));
        }
    }
    if !ram_root {
        return Err(io::Error::other("requires RAM root"));
    }
    let compatible = fs::read("/proc/device-tree/compatible")?;
    let meson6 = compatible
        .split(|b| *b == 0)
        .any(|v| v == b"AMLOGIC,8726_MX");
    let release = fs::read_to_string("/proc/sys/kernel/osrelease")?;
    let stock = meson6 && release.trim() == "3.10.33";
    let development = meson6 && development_kernel_allowed(release.trim());
    let qemu = compatible
        .split(|b| *b == 0)
        .any(|v| v == b"linux,dummy-virt")
        && fs::read_to_string("/proc/cmdline")?
            .split_whitespace()
            .any(|v| v == "mibox.test_restart=1");
    if !stock && !development && !qemu {
        return Err(io::Error::other("restart platform guard"));
    }
    Ok(fs::read_to_string("/proc/sys/kernel/random/boot_id")?
        .trim()
        .to_owned())
}

fn handle(mut stream: UnixStream, hardware: fn(&str) -> io::Result<String>) -> io::Result<()> {
    stream.set_write_timeout(Some(Duration::from_secs(2)))?;
    if !matches!(credentials(&stream)?.uid, 0 | 2000) {
        return Err(io::Error::other("control peer UID denied"));
    }
    let request = bounded_request(&mut stream)?;
    let boot_id = readiness()?;
    if request == b"CHECK\n" {
        writeln!(stream, "MIBOX_RESTART_READY boot_id={boot_id}")?;
    } else if request == format!("RESTART {boot_id}\n").as_bytes() {
        // Acceptance alone is not proof of a successful Android return.
        stream.write_all(ACCEPTED.as_bytes())?;
        eprintln!("MIBOX_NORMAL_RESTART_REQUESTED boot_id={boot_id}");
        if unsafe { reboot(0x01234567) } != 0 {
            // LINUX_REBOOT_CMD_RESTART, no mode argument
            return Err(io::Error::last_os_error());
        }
    } else if cfg!(feature = "loader-restart")
        && request == format!("LOADER {boot_id}\n").as_bytes()
    {
        stream.write_all(LOADER_ACCEPTED.as_bytes())?;
        eprintln!("MIBOX_LOADER_RESTART_REQUESTED boot_id={boot_id}");
        #[cfg(feature = "loader-restart")]
        return Err(loader_restart());
    } else if let Some(action) = ["network", "display", "audio", "capture"]
        .into_iter()
        .find(|action| request == format!("HARDWARE {action} {boot_id}\n").as_bytes())
    {
        // The helper is bounded separately; never accept a path or shell text.
        stream.set_write_timeout(Some(Duration::from_secs(3)))?;
        let output = hardware(action)?;
        stream.write_all(output.as_bytes())?;
    } else {
        return Err(io::Error::other("invalid command or stale boot ID"));
    }
    Ok(())
}

pub fn serve(hardware: fn(&str) -> io::Result<String>) -> io::Result<()> {
    if std::process::id() != 1 || unsafe { getuid() } != 0 {
        return Err(io::Error::other("control listener requires root PID1"));
    }
    // Never unlink an existing object. /dev is root owned and not user writable.
    let listener = UnixListener::bind(SOCKET)?;
    fs::set_permissions(SOCKET, fs::Permissions::from_mode(0o666))?;
    eprintln!("MIBOX_RAM_CONTROL_READY");
    for stream in listener.incoming() {
        match stream.and_then(|stream| handle(stream, hardware)) {
            Ok(()) => {}
            Err(error) => eprintln!("mibox-control: {error}"),
        }
    }
    Ok(())
}

pub fn hardware_request(action: &str, expected_boot_id: &str) -> io::Result<()> {
    if !matches!(action, "network" | "display" | "audio" | "capture") {
        return Err(io::Error::other("hardware action denied"));
    }
    let boot_id = fs::read_to_string("/proc/sys/kernel/random/boot_id")?;
    if expected_boot_id != boot_id.trim() {
        return Err(io::Error::other("hardware boot ID mismatch"));
    }
    let mut stream = UnixStream::connect(SOCKET)?;
    let peer = credentials(&stream)?;
    if peer.uid != 0 || peer.pid != 1 {
        return Err(io::Error::other("hardware server is not root PID1"));
    }
    stream.set_write_timeout(Some(Duration::from_secs(3)))?;
    stream.set_read_timeout(Some(Duration::from_secs(60)))?;
    writeln!(stream, "HARDWARE {action} {expected_boot_id}")?;
    stream.shutdown(std::net::Shutdown::Write)?;
    let mut response = String::new();
    (&mut stream).take(16385).read_to_string(&mut response)?;
    print!("{response}");
    if response.len() > 16384 || !response.ends_with("MIBOX_HARDWARE_EXIT=0\n") {
        return Err(io::Error::other(
            "hardware helper failed or response invalid",
        ));
    }
    Ok(())
}

pub fn request(restart_boot_id: Option<&str>) -> io::Result<()> {
    send(restart_boot_id, "RESTART", ACCEPTED)
}

/// Client for the LOADER request; the server decides whether it is built in.
pub fn request_loader(boot_id: &str) -> io::Result<()> {
    send(Some(boot_id), "LOADER", LOADER_ACCEPTED)
}

fn send(restart_boot_id: Option<&str>, verb: &str, accepted: &str) -> io::Result<()> {
    let mut stream = UnixStream::connect(SOCKET)?;
    let peer = credentials(&stream)?;
    if peer.uid != 0 || peer.pid != 1 {
        return Err(io::Error::other("control server is not root PID1"));
    }
    stream.set_write_timeout(Some(Duration::from_secs(3)))?;
    stream.set_read_timeout(Some(Duration::from_secs(3)))?;
    let boot_id = fs::read_to_string("/proc/sys/kernel/random/boot_id")?;
    if let Some(expected) = restart_boot_id {
        if expected != boot_id.trim() {
            return Err(io::Error::other("boot ID does not match current boot"));
        }
        writeln!(stream, "{verb} {expected}")?;
    } else {
        stream.write_all(b"CHECK\n")?;
    }
    stream.shutdown(std::net::Shutdown::Write)?;
    let mut response = String::new();
    (&mut stream).take(257).read_to_string(&mut response)?;
    let expected = if restart_boot_id.is_some() {
        accepted.to_owned()
    } else {
        format!("MIBOX_RESTART_READY boot_id={}\n", boot_id.trim())
    };
    if response != expected {
        return Err(io::Error::other(
            "control request rejected or invalid response",
        ));
    }
    print!("{response}");
    Ok(())
}
