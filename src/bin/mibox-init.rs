//! Minimal RAM-only PID1 candidate. Not yet boot-tested on MiBOX1S.
//! Outside PID1 it only prints a report; it never changes mounts or devices.
use std::ffi::CString;
use std::fs::{self, OpenOptions};
use std::io::{self, BufRead, BufReader, Write};
use std::os::raw::{c_char, c_int, c_ulong, c_void};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicI32, Ordering};
use std::sync::Mutex;
use std::thread;
use std::time::Duration;

#[path = "../android_properties.rs"]
mod android_properties;
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

fn serve_console(device: &str) -> io::Result<()> {
    let console = OpenOptions::new().read(true).write(true).open(device)?;
    let mut output = console.try_clone()?;
    writeln!(output, "{}MIBOX_INIT_CONSOLE_READY", report())?;
    writeln!(
        output,
        "Commands: help, info, uptime, reaptest, os, files. Persistent storage is not mounted."
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
            "help" => writeln!(output, "help | info | uptime | reaptest | os | files")?,
            command @ ("os" | "files" | "adbprobe") => {
                // Prevent PID1's generic reaper from collecting a child owned
                // by Command::output before it retrieves that child's status.
                let _guard = REAPER_LOCK
                    .lock()
                    .unwrap_or_else(|error| error.into_inner());
                let args: &[&str] = if command == "os" {
                    &["info"]
                } else {
                    &["ls", "/"]
                };
                if command == "adbprobe" {
                    let status = Command::new("/bin/mibox-adb-probe")
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
    let adb_requested = usb_adb::requested();
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
