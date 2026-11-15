//! Minimal RAM-only PID1. The original baseline passed physical MiBOX1S boot.
//! Subsequent changes require fresh candidate and physical validation.
//! Outside PID1 it only prints a report; it never changes mounts or devices.
use std::ffi::CString;
use std::fs::{self, OpenOptions};
use std::io::{self, BufRead, BufReader, Read, Write};
use std::os::raw::{c_char, c_int, c_ulong, c_void};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicI32, Ordering};
use std::sync::Mutex;
use std::thread;
use std::time::Duration;

#[path = "../android_properties.rs"]
mod android_properties;
#[path = "../ram_control.rs"]
#[allow(dead_code)]
mod ram_control;
#[path = "../runtime_health.rs"]
mod runtime_health;
#[path = "../usb_adb.rs"]
mod usb_adb;
#[path = "../usb_console.rs"]
mod usb_console;

static LAST_REAPED: AtomicI32 = AtomicI32::new(0);
static REAPER_LOCK: Mutex<()> = Mutex::new(());

unsafe extern "C" {
    fn mount(
        source: *const c_char,
        target: *const c_char,
        kind: *const c_char,
        flags: c_ulong,
        data: *const c_void,
    ) -> c_int;
    fn waitpid(pid: c_int, status: *mut c_int, options: c_int) -> c_int;
}

fn report() -> String {
    let version = fs::read_to_string("/proc/version").unwrap_or_else(|e| e.to_string());
    format!(
        "mibox-init {}\npid={} arch={}\n{}\n",
        env!("CARGO_PKG_VERSION"),
        std::process::id(),
        std::env::consts::ARCH,
        version.trim()
    )
}

fn mount_ram_fs(kind: &str, target: &str) -> io::Result<()> {
    fs::create_dir_all(target)?;
    let source = CString::new(kind)?;
    let path = CString::new(target)?;
    // All call sites use kernel virtual filesystems, never eMMC partitions.
    let flags: c_ulong = 2 | 8; // MS_NOSUID | MS_NOEXEC
    let result = unsafe {
        mount(
            source.as_ptr(),
            path.as_ptr(),
            source.as_ptr(),
            flags,
            std::ptr::null(),
        )
    };
    if result == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

fn hold() -> ! {
    loop {
        thread::sleep(Duration::from_secs(1));
    }
}

fn hardware_test(action: &str) -> io::Result<String> {
    if !matches!(action, "network" | "display" | "audio" | "capture") {
        return Err(io::Error::other("hardware action denied"));
    }
    let _guard = REAPER_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let mut child = Command::new("/sbin/mibox-hardware")
        .arg(action)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    let started = std::time::Instant::now();
    let status = loop {
        if let Some(status) = child.try_wait()? {
            break status;
        }
        if started.elapsed() > Duration::from_secs(50) {
            child.kill()?;
            child.wait()?;
            return Ok("MIBOX_HARDWARE_TIMEOUT\nMIBOX_HARDWARE_EXIT=1\n".into());
        }
        thread::sleep(Duration::from_millis(50));
    };
    let mut output = String::new();
    child
        .stdout
        .take()
        .unwrap()
        .take(8192)
        .read_to_string(&mut output)?;
    child
        .stderr
        .take()
        .unwrap()
        .take(8192)
        .read_to_string(&mut output)?;
    output.push_str(&format!(
        "MIBOX_HARDWARE_EXIT={}\n",
        status.code().unwrap_or(1)
    ));
    Ok(output)
}

fn serve_console(device: &str) -> io::Result<()> {
    let console = OpenOptions::new().read(true).write(true).open(device)?;
    let mut output = console.try_clone()?;
    writeln!(output, "{}MIBOX_INIT_CONSOLE_READY", report())?;
    writeln!(
        output,
        "Commands: help, info, uptime, health, reaptest, os, files. Persistent storage is not mounted."
    )?;
    let mut reader = BufReader::new(console);
    loop {
        write!(output, "mibox> ")?;
        output.flush()?;
        let mut line = String::new();
        // Bound one line's allocation even if the physical console sends junk.
        loop {
            let bytes = reader.fill_buf()?;
            if bytes.is_empty() {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "console closed",
                ));
            }
            let take = bytes
                .iter()
                .position(|b| *b == b'\n')
                .map_or(bytes.len(), |n| n + 1);
            let ends_line = bytes[take - 1] == b'\n';
            if line.len() + take > 256 {
                return Err(io::Error::other("console line exceeds 256 bytes"));
            }
            line.push_str(&String::from_utf8_lossy(&bytes[..take]));
            reader.consume(take);
            if ends_line {
                break;
            }
        }
        match line.trim() {
            "help" => writeln!(
                output,
                "help | info | uptime | health | reaptest | os | files"
            )?,
            "health" => write!(output, "{}", runtime_health::snapshot())?,
            command @ ("os" | "files" | "adbprobe" | "restartprobe" | "hardware-selftest"
            | "hardware-guard") => {
                // Prevent PID1's generic reaper from collecting a child owned
                // by Command::output before it retrieves that child's status.
                let _guard = REAPER_LOCK
                    .lock()
                    .unwrap_or_else(|error| error.into_inner());
                if matches!(command, "hardware-selftest" | "hardware-guard") {
                    // Diagnostic console commands never request live hardware writes.
                    if command == "hardware-guard"
                        && !fs::read("/proc/device-tree/compatible")?
                            .split(|b| *b == 0)
                            .any(|value| value == b"linux,dummy-virt")
                    {
                        writeln!(output, "hardware-guard is QEMU-only")?;
                        continue;
                    }
                    let result = Command::new("/sbin/mibox-hardware")
                        .arg(if command == "hardware-selftest" {
                            "selftest"
                        } else {
                            "network"
                        })
                        .output()?;
                    output.write_all(&result.stdout)?;
                    output.write_all(&result.stderr)?;
                    writeln!(
                        output,
                        "HARDWARE_DIAGNOSTIC_EXIT={}",
                        result.status.code().unwrap_or(1)
                    )?;
                    continue;
                }
                let args: &[&str] = if command == "os" {
                    &["info"]
                } else {
                    &["ls", "/"]
                };
                if command == "adbprobe" || command == "restartprobe" {
                    let status = Command::new(if command == "adbprobe" {
                        "/bin/mibox-adb-probe"
                    } else {
                        "/bin/mibox-restart-probe"
                    })
                    .stdin(Stdio::from(reader.get_ref().try_clone()?))
                    .stdout(Stdio::from(reader.get_ref().try_clone()?))
                    .stderr(Stdio::from(reader.get_ref().try_clone()?))
                    .status()?;
                    if !status.success() {
                        writeln!(output, "USERSPACE_COMMAND_FAILED {:?}", status.code())?;
                    }
                    continue;
                }
                let result = Command::new("/bin/mibox").args(args).output()?;
                output.write_all(&result.stdout)?;
                output.write_all(&result.stderr)?;
                if !result.status.success() {
                    writeln!(
                        output,
                        "USERSPACE_COMMAND_FAILED {:?}",
                        result.status.code()
                    )?;
                }
            }
            "info" => write!(output, "{}", report())?,
            "uptime" => writeln!(output, "{}", fs::read_to_string("/proc/uptime")?.trim())?,
            "reaptest" => {
                let child = Command::new("/init")
                    .arg("--reaper-probe")
                    .stdin(Stdio::null())
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .spawn()?;
                let pid = child.id() as c_int;
                drop(child); // PID1's reaper, not Child::wait, must collect it.
                let mut reaped = false;
                for _ in 0..200 {
                    if LAST_REAPED.load(Ordering::SeqCst) == pid {
                        reaped = true;
                        break;
                    }
                    thread::sleep(Duration::from_millis(10));
                }
                if reaped {
                    writeln!(output, "REAP_OK pid={pid}")?;
                } else {
                    writeln!(output, "REAP_FAILED pid={pid}")?;
                }
            }
            "" => {}
            _ => writeln!(output, "Unknown command; type help.")?,
        }
    }
}

fn main() {
    if std::process::id() != 1 {
        print!("{}MIBOX_INIT_INSPECT_ONLY\n", report());
        return;
    }
    // A PID1 panic must not return to the runtime and terminate the process.
    std::panic::set_hook(Box::new(|info| {
        eprintln!("mibox-init panic: {info}");
        hold();
    }));
    for (kind, path) in [("proc", "/proc"), ("sysfs", "/sys"), ("devtmpfs", "/dev")] {
        if let Err(error) = mount_ram_fs(kind, path) {
            eprintln!("mibox-init: cannot mount {kind} on {path}: {error}; holding");
            hold();
        }
    }
    #[cfg(feature = "container-kernel-test")]
    if ram_control::development_kernel_allowed(
        fs::read_to_string("/proc/sys/kernel/osrelease")
            .unwrap_or_default()
            .trim(),
    ) {
        // Run before the reaper thread starts; the helper uses private
        // namespaces and never mounts persistent storage.
        let result = (|| -> io::Result<()> {
            fs::create_dir_all("/tmp")?;
            let output = fs::File::create("/tmp/mibox-kernel-selftest.txt")?;
            let mut child = Command::new("/sbin/mibox-kernel-selftest")
                .stdin(Stdio::null())
                .stdout(output.try_clone()?)
                .stderr(output)
                .spawn()?;
            let started = std::time::Instant::now();
            loop {
                if let Some(status) = child.try_wait()? {
                    eprintln!("MIBOX_KERNEL_SELFTEST_EXIT={}", status.code().unwrap_or(1));
                    return Ok(());
                }
                if started.elapsed() > Duration::from_secs(35) {
                    child.kill()?;
                    child.wait()?;
                    return Err(io::Error::other("kernel selftest timed out"));
                }
                thread::sleep(Duration::from_millis(50));
            }
        })();
        if let Err(error) = result {
            eprintln!("mibox-init: kernel selftest unavailable: {error}");
        }
    }
    let adb_requested = usb_adb::requested();
    thread::spawn(|| {
        if let Err(error) = ram_control::serve(hardware_test) {
            eprintln!("mibox-init: RAM control unavailable: {error}");
        }
    });
    let acm_requested = usb_console::requested();
    if adb_requested && acm_requested {
        eprintln!("mibox-init: conflicting USB requests; keeping /dev/console");
    } else if adb_requested {
        match usb_adb::start() {
            Ok(pid) => eprintln!(
                "MIBOX_USB_ADB_SPAWNED pid={pid}; public-key authentication required; USB only"
            ),
            Err(error) => eprintln!("mibox-init: USB ADB unavailable: {error}; using /dev/console"),
        }
    }
    let console_device = if acm_requested && !adb_requested {
        match usb_console::enable() {
            Ok(device) => device,
            Err(error) => {
                eprintln!("mibox-init: USB ACM unavailable: {error}; using /dev/console");
                "/dev/console"
            }
        }
    } else {
        "/dev/console"
    };
    // Start after USB setup so both consoles use the same devpts mount.
    // This script is absent in all earlier RAM candidates.
    if std::path::Path::new("/sbin/mibox-console-start").is_file() {
        match Command::new("/bin/sh")
            .arg("/sbin/mibox-console-start")
            .stdin(Stdio::null())
            .spawn()
        {
            Ok(child) => eprintln!("MIBOX_CONSOLE_START_SPAWNED pid={}", child.id()),
            Err(error) => eprintln!("mibox-init: console services unavailable: {error}"),
        }
    }
    thread::spawn(|| loop {
        let mut status = 0;
        {
            let _guard = REAPER_LOCK
                .lock()
                .unwrap_or_else(|error| error.into_inner());
            loop {
                let pid = unsafe { waitpid(-1, &mut status, 1) }; // WNOHANG
                if pid <= 0 {
                    break;
                }
                LAST_REAPED.store(pid, Ordering::SeqCst);
            }
        }
        thread::sleep(Duration::from_millis(100));
    });
    loop {
        if let Err(error) = serve_console(console_device) {
            eprintln!("mibox-init: console unavailable: {error}; retrying");
        }
        thread::sleep(Duration::from_secs(1));
    }
}
