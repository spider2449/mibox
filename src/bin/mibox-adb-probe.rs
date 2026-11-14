//! QEMU-only compatibility test for the exact stock recovery adbd and shell.
#[path = "../android_properties.rs"]
mod android_properties;
use std::{
    fs,
    io::{self, BufRead, Read, Write},
    net::{TcpStream, UdpSocket},
    os::{
        fd::AsRawFd,
        unix::{
            fs::{MetadataExt, PermissionsExt},
            process::CommandExt,
        },
    },
    process::{Child, Command, Stdio},
    thread,
    time::Duration,
};

unsafe extern "C" {
    fn ioctl(fd: i32, request: u32, ...) -> i32;
    fn ptrace(request: i32, pid: i32, address: *mut u8, data: *mut u8) -> i32;
    fn waitpid(pid: i32, status: *mut i32, options: i32) -> i32;
    fn mount(
        source: *const std::os::raw::c_char,
        target: *const std::os::raw::c_char,
        kind: *const std::os::raw::c_char,
        flags: u32,
        data: *const u8,
    ) -> i32;
}
struct Daemon(Child);
impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}
fn trace_adbd() -> io::Result<()> {
    let mut command = Command::new("/sbin/adbd");
    command
        .arg("recovery")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    unsafe {
        command.pre_exec(|| {
            if ptrace(0, 0, std::ptr::null_mut(), std::ptr::null_mut()) < 0 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let child = Daemon(command.spawn()?);
    let pid = child.0.id() as i32;
    for _ in 0..8 {
        let mut status = 0;
        let mut ready = false;
        for _ in 0..300 {
            let result = unsafe { waitpid(pid, &mut status, 1) };
            if result < 0 {
                return Err(io::Error::last_os_error());
            }
            if result == pid {
                ready = true;
                break;
            }
            thread::sleep(Duration::from_millis(10));
        }
        if !ready {
            return Err(io::Error::other("bounded ptrace wait timed out"));
        }
        if status & 0xff != 0x7f {
            println!("ADB_TRACE_EXIT={status:#x}");
            return Ok(());
        }
        let signal = (status >> 8) & 0xff;
        if signal == 11 {
            let mut registers = [0u32; 18];
            if unsafe { ptrace(12, pid, std::ptr::null_mut(), registers.as_mut_ptr().cast()) } < 0 {
                return Err(io::Error::last_os_error());
            }
            let mut signal_info = [0u32; 32];
            let _ = unsafe {
                ptrace(
                    0x4202,
                    pid,
                    std::ptr::null_mut(),
                    signal_info.as_mut_ptr().cast(),
                )
            };
            println!(
                "ADB_TRACE_SIGSEGV pc={:#x} lr={:#x} sp={:#x} fault={:#x} registers={registers:x?}",
                registers[15], registers[14], registers[13], signal_info[3]
            );
            println!(
                "ADB_TRACE_MAPS\n{}",
                fs::read_to_string(format!("/proc/{pid}/maps"))?
            );
            return Ok(());
        }
        if unsafe { ptrace(7, pid, std::ptr::null_mut(), std::ptr::null_mut()) } < 0 {
            return Err(io::Error::last_os_error());
        }
    }
    Err(io::Error::other("bounded ptrace stop limit reached"))
}
fn send(
    stream: &mut TcpStream,
    kind: &[u8; 4],
    arg0: u32,
    arg1: u32,
    payload: &[u8],
) -> io::Result<()> {
    let command = u32::from_le_bytes(*kind);
    for value in [
        command,
        arg0,
        arg1,
        payload.len() as u32,
        payload.iter().map(|v| *v as u32).sum(),
        command ^ u32::MAX,
    ] {
        stream.write_all(&value.to_le_bytes())?;
    }
    stream.write_all(payload)
}
fn receive(stream: &mut TcpStream) -> io::Result<([u8; 4], u32, u32, Vec<u8>)> {
    let mut header = [0u8; 24];
    stream.read_exact(&mut header)?;
    let word = |offset| u32::from_le_bytes(header[offset..offset + 4].try_into().unwrap());
    let command = word(0);
    let length = word(12) as usize;
    if word(20) != command ^ u32::MAX || length > 65536 {
        return Err(io::Error::other("invalid ADB header"));
    }
    let mut payload = vec![0u8; length];
    stream.read_exact(&mut payload)?;
    if payload.iter().map(|v| *v as u32).sum::<u32>() != word(16) {
        return Err(io::Error::other("ADB checksum mismatch"));
    }
    Ok((command.to_le_bytes(), word(4), word(8), payload))
}
fn probe() -> io::Result<()> {
    let cmdline = fs::read_to_string("/proc/cmdline")?;
    let compatible = fs::read("/proc/device-tree/compatible")?;
    if !cmdline.split_whitespace().any(|v| v == "mibox.test_adb=1")
        || !compatible
            .split(|b| *b == 0)
            .any(|v| v == b"linux,dummy-virt")
    {
        return Err(io::Error::other(
            "QEMU-only probe: explicit test flag and virt DT required",
        ));
    }
    if fs::metadata("/sys/class/android_usb/android0").is_ok() {
        return Err(io::Error::other("refuse any Android USB gadget hardware"));
    }
    let authenticated = cmdline
        .split_whitespace()
        .any(|v| v == "mibox.test_adb_auth=1");
    // Android 4.4 bionic dereferences its shared property area even for a
    // missing property. Supply an empty, read-only ABI-compatible area in
    // this isolated QEMU rootfs; never copy or alter device properties.
    let values: &[(&str, &str)] = if authenticated {
        android_properties::AUTHENTICATED_ADB_PROPERTIES
    } else {
        &[]
    };
    let area = android_properties::build(values)?;
    if authenticated && !fs::metadata("/adb_keys")?.is_file() {
        return Err(io::Error::other("QEMU public key absent"));
    }
    let mut properties = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open("/dev/__properties__")?;
    properties.write_all(&area)?;
    properties.sync_all()?;
    fs::set_permissions("/dev/__properties__", fs::Permissions::from_mode(0o444))?;
    let metadata = properties.metadata()?;
    if metadata.uid() != 0 || metadata.gid() != 0 {
        return Err(io::Error::other("property area must be root:root"));
    }
    drop(properties);
    println!("MIBOX_QEMU_PROPERTY_AREA_READY authenticated={authenticated}");
    fs::create_dir_all("/dev/pts")?;
    if unsafe {
        mount(
            c"devpts".as_ptr(),
            c"/dev/pts".as_ptr(),
            c"devpts".as_ptr(),
            2 | 8,
            std::ptr::null(),
        )
    } != 0
    {
        return Err(io::Error::last_os_error());
    }
    let network = UdpSocket::bind("0.0.0.0:0")?;
    let mut request = [0u8; 40];
    request[..2].copy_from_slice(b"lo");
    if unsafe { ioctl(network.as_raw_fd(), 0x8913, request.as_mut_ptr()) } != 0 {
        return Err(io::Error::last_os_error());
    }
    let flags = i16::from_ne_bytes(request[16..18].try_into().unwrap()) | 1;
    request[16..18].copy_from_slice(&flags.to_ne_bytes());
    if unsafe { ioctl(network.as_raw_fd(), 0x8914, request.as_mut_ptr()) } != 0 {
        return Err(io::Error::last_os_error());
    }
    let shell = Command::new("/system/bin/sh")
        .args(["-c", "/bin/mibox info"])
        .output()?;
    if !shell.status.success() {
        return Err(io::Error::other(format!(
            "stock shell exited: {}; stderr={}",
            shell.status,
            String::from_utf8_lossy(&shell.stderr)
        )));
    }
    if !String::from_utf8_lossy(&shell.stdout).contains("ID=mibox-custom") {
        return Err(io::Error::other(
            "stock shell did not execute custom toolbox",
        ));
    }
    println!("MIBOX_STOCK_SHELL_OK");
    let log = fs::File::create("/tmp/adbd-probe.log")?;
    let mut daemon = Daemon(
        Command::new("/sbin/adbd")
            .arg("recovery")
            .stdin(Stdio::null())
            .stdout(log.try_clone()?)
            .stderr(log)
            .spawn()?,
    );
    let mut connection = None;
    for _ in 0..100 {
        if let Ok(stream) = TcpStream::connect("127.0.0.1:5555") {
            connection = Some(stream);
            break;
        }
        if let Some(status) = daemon.0.try_wait()? {
            if let Err(error) = trace_adbd() {
                println!("ADB_TRACE_ERROR={error}");
            }
            return Err(io::Error::other(format!("adbd exited: {status}")));
        }
        thread::sleep(Duration::from_millis(50));
    }
    let mut stream =
        connection.ok_or_else(|| io::Error::other("adbd did not listen on guest loopback"))?;
    stream.set_read_timeout(Some(Duration::from_secs(5)))?;
    stream.set_write_timeout(Some(Duration::from_secs(5)))?;
    send(&mut stream, b"CNXN", 0x01000000, 4096, b"host::\0")?;
    let (mut kind, auth_kind, _, mut banner) = receive(&mut stream)?;
    if authenticated {
        if &kind != b"AUTH" || auth_kind != 1 || banner.len() != 20 {
            return Err(io::Error::other(
                "secure daemon did not require authentication",
            ));
        }
        send(&mut stream, b"AUTH", 2, 0, &[0u8; 256])?;
        let (next_kind, next_auth, _, token) = receive(&mut stream)?;
        if &next_kind != b"AUTH" || next_auth != 1 || token.len() != 20 {
            return Err(io::Error::other("daemon accepted invalid signature"));
        }
        println!("MIBOX_QEMU_ADB_BAD_SIGNATURE_REJECTED");
        println!(
            "ADB_AUTH_TOKEN_HEX={}",
            token
                .iter()
                .map(|value| format!("{value:02x}"))
                .collect::<String>()
        );
        io::stdout().flush()?;
        let mut line = String::new();
        io::stdin().lock().take(1024).read_line(&mut line)?;
        let hex = line.trim();
        if hex.len() != 512 {
            return Err(io::Error::other("expected 256-byte host signature"));
        }
        let signature = hex
            .as_bytes()
            .chunks_exact(2)
            .map(|part| {
                u8::from_str_radix(std::str::from_utf8(part).map_err(io::Error::other)?, 16)
                    .map_err(io::Error::other)
            })
            .collect::<io::Result<Vec<_>>>()?;
        send(&mut stream, b"AUTH", 2, 0, &signature)?;
        let response = receive(&mut stream)?;
        kind = response.0;
        banner = response.3;
    } else if &kind == b"AUTH" {
        return Err(io::Error::other(
            "unexpected authentication challenge; do not bypass",
        ));
    }
    if &kind != b"CNXN" {
        return Err(io::Error::other("unexpected handshake reply"));
    }
    if authenticated && !String::from_utf8_lossy(&banner).contains("ro.product.device=casablanca;")
    {
        return Err(io::Error::other(
            "daemon did not read the full candidate property set",
        ));
    }
    println!(
        "ADB_BANNER={}",
        String::from_utf8_lossy(&banner).trim_end_matches('\0')
    );
    send(&mut stream, b"OPEN", 1, 0, b"shell:/bin/mibox info\0")?;
    let mut transcript = Vec::new();
    let mut closed = false;
    for _ in 0..100 {
        let (kind, remote, local, payload) = receive(&mut stream)?;
        if local != 1 {
            return Err(io::Error::other("unexpected ADB stream id"));
        }
        match &kind {
            b"OKAY" => {}
            b"WRTE" => {
                if transcript.len() + payload.len() > 16384 {
                    return Err(io::Error::other("shell output exceeds bound"));
                }
                transcript.extend_from_slice(&payload);
                send(&mut stream, b"OKAY", 1, remote, b"")?;
            }
            b"CLSE" => {
                send(&mut stream, b"CLSE", 1, remote, b"")?;
                closed = true;
                break;
            }
            _ => return Err(io::Error::other("unexpected shell packet")),
        }
    }
    let text = String::from_utf8_lossy(&transcript);
    print!("{text}");
    if !closed || !text.contains("ID=mibox-custom") || !text.contains("kernel=") {
        return Err(io::Error::other(
            "custom userspace shell response not confirmed",
        ));
    }
    drop(daemon);
    println!("MIBOX_QEMU_ADB_CONSOLE_OK daemon=stock shell=stock toolbox=custom transport=guest-loopback authenticated={authenticated}");
    Ok(())
}
fn main() -> io::Result<()> {
    let result = probe();
    if result.is_err() {
        if let Ok(log) = fs::read_to_string("/tmp/adbd-probe.log") {
            eprintln!("{log}");
        }
    }
    result
}
