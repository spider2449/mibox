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
#[path = "../fail_safe.rs"]
mod fail_safe;
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

/// Starts the requested USB control function and returns the console device.
/// No request means /dev/console only, which is ready immediately.
fn setup_usb() -> io::Result<&'static str> {
    match fail_safe::injected() {
        Some("usb") => return Err(io::Error::other("injected USB setup fault")),
        Some("hang") => loop {
            thread::sleep(Duration::from_secs(1));
        },
        _ => {}
    }
    let adb_requested = usb_adb::requested();
    let acm_requested = usb_console::requested();
    if adb_requested && acm_requested {
        return Err(io::Error::other("conflicting USB ADB and ACM requests"));
    }
    if adb_requested {
        let pid = usb_adb::start()?;
        eprintln!("MIBOX_USB_ADB_SPAWNED pid={pid}; public-key authentication required; USB only");
        return Ok("/dev/console");
    }
    if acm_requested {
        return usb_console::enable();
    }
    Ok("/dev/console")
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
    // The hook never returns; it restarts through the preboot USB window.
    std::panic::set_hook(Box::new(|info| {
        eprintln!("mibox-init panic: {info}");
        fail_safe::restart("panic");
    }));
    for (kind, path) in [("proc", "/proc"), ("sysfs", "/sys"), ("devtmpfs", "/dev")] {
        if let Err(error) = mount_ram_fs(kind, path) {
            eprintln!("mibox-init: cannot mount {kind} on {path}: {error}");
            fail_safe::restart("virtual-filesystem");
        }
    }
    if let Some(fault) = fail_safe::injected() {
        eprintln!("MIBOX_FAULT_INJECTED={fault}");
        if fault == "panic" {
            panic!("injected early fault");
        }
        if fault == "kpanic" {
            // Bypasses the PID1 fail-safe on purpose: PID1 exit makes the kernel
            // panic ("Attempted to kill init"), testing kernel.panic=20 restart.
            eprintln!("MIBOX_KERNEL_PANIC_TEST pid1-exit");
            std::process::exit(1);
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
    thread::spawn(|| {
        if let Err(error) = ram_control::serve(hardware_test) {
            eprintln!("mibox-init: RAM control unavailable: {error}");
        }
    });
    // A requested USB control path that fails or stalls leaves no remote
    // access, so it restarts to the USB loader window instead of continuing.
    let (setup_done, setup_result) = std::sync::mpsc::channel();
    thread::spawn(move || {
        let _ = setup_done.send(setup_usb());
    });
    let console_device = match setup_result.recv_timeout(fail_safe::SETUP_DEADLINE) {
        Ok(Ok(device)) => device,
        Ok(Err(error)) => {
            eprintln!("mibox-init: USB setup failed: {error}");
            fail_safe::restart("usb-setup");
        }
        Err(_) => {
            eprintln!(
                "mibox-init: USB setup unfinished after {} s",
                fail_safe::SETUP_DEADLINE.as_secs()
            );
            fail_safe::restart("usb-setup-deadline");
        }
    };
    eprintln!("MIBOX_SETUP_READY console={console_device}");
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
