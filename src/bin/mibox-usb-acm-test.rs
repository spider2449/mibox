//! One bounded ACM experiment on the owner's box, with device-side rollback.
//! No boot/property/SELinux changes. Only fixed USB gadget attributes are changed.
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::os::unix::net::UnixDatagram;
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

const BASE: &str = "/sys/class/android_usb/android0";
const STATE: &str = "/data/local/tmp/mibox-acm-test-v3";
const EXE: &str = "/data/local/tmp/mibox-usb-acm-test";
// A deployed revision showed a reset and missing restore evidence. Live tests
// remain disabled pending retained-log/legacy-driver investigation.
const LIVE_EXPERIMENT_ENABLED: bool = false;
const ATTRS: &[&str] = &[
    "enable",
    "idVendor",
    "idProduct",
    "bDeviceClass",
    "bDeviceSubClass",
    "bDeviceProtocol",
    "f_acm/instances",
    "functions",
];

unsafe extern "C" {
    fn geteuid() -> u32;
}

fn state_file(attribute: &str) -> String {
    format!("{STATE}/{}", attribute.replace('/', "_"))
}
fn note(message: &str) {
    if let Ok(mut file) = OpenOptions::new()
        .create(true)
        .append(true)
        .open(format!("{STATE}/log.txt"))
    {
        let millis = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_millis());
        let _ = writeln!(
            file,
            "pid={} epoch_ms={millis} {message}",
            std::process::id()
        );
        let _ = fs::set_permissions(
            format!("{STATE}/log.txt"),
            fs::Permissions::from_mode(0o644),
        );
    }
}
fn set(attribute: &str, value: &str) -> io::Result<()> {
    fs::write(format!("{BASE}/{attribute}"), value.as_bytes())
}
fn restore() -> io::Result<()> {
    let mut failures = Vec::new();
    if let Err(error) = set("enable", "0") {
        failures.push(format!("disable: {error}"));
    }
    // Clear the active ACM function before resetting its instance count.
    let order = [
        "functions",
        "f_acm/instances",
        "idVendor",
        "idProduct",
        "bDeviceClass",
        "bDeviceSubClass",
        "bDeviceProtocol",
        "enable",
    ];
    for attribute in order {
        match fs::read_to_string(state_file(attribute)) {
            Ok(value) => {
                if let Err(error) = set(attribute, value.trim()) {
                    failures.push(format!("{attribute}: {error}"));
                }
            }
            Err(error) => failures.push(format!("saved {attribute}: {error}")),
        }
    }
    for attribute in ATTRS {
        match (
            fs::read_to_string(state_file(attribute)),
            fs::read_to_string(format!("{BASE}/{attribute}")),
        ) {
            (Ok(expected), Ok(actual)) if expected.trim() == actual.trim() => {}
            _ => failures.push(format!("readback mismatch: {attribute}")),
        }
    }
    if failures.is_empty() {
        fs::write(format!("{STATE}/restored"), b"USB_STATE_RESTORED\n")?;
        fs::set_permissions(
            format!("{STATE}/restored"),
            fs::Permissions::from_mode(0o644),
        )?;
        note("USB_STATE_RESTORED");
        Ok(())
    } else {
        note(&format!("RESTORE_ERRORS: {}", failures.join("; ")));
        Err(io::Error::other("USB restore did not verify"))
    }
}

fn experiment() -> io::Result<()> {
    // Delay makes the launcher finish while ADB is still connected.
    thread::sleep(Duration::from_secs(5));
    set("enable", "0")?;
    set("f_acm/instances", "1")?;
    set("idVendor", "18d1")?;
    // 4e41 is present in this box's original init.amlogic.usb.rc and is not an
    // exact hardware-ID match in the inspected host OEM drivers. The earlier
    // 4e21 experiment collided with Google's whole-device ADB driver.
    set("idProduct", "4e41")?;
    set("bDeviceClass", "02")?;
    set("bDeviceSubClass", "02")?;
    set("bDeviceProtocol", "01")?;
    set("functions", "acm")?;
    set("enable", "1")?;
    note("ACM_ENABLED: 18d1:4e41 class=02 subclass=02 protocol=01");
    let mut serial = OpenOptions::new()
        .read(true)
        .write(true)
        .custom_flags(0x800)
        .open("/dev/ttyGS0")?; // Linux O_NONBLOCK
    let deadline = Instant::now() + Duration::from_secs(25);
    let mut input = String::new();
    let mut last_announcement = Instant::now() - Duration::from_secs(1);
    let mut acknowledged = false;
    while Instant::now() < deadline {
        if last_announcement.elapsed() >= Duration::from_millis(500) {
            let _ = serial.write(b"MIBOX_ACM_READY\n");
            last_announcement = Instant::now();
        }
        let mut bytes = [0u8; 256];
        match serial.read(&mut bytes) {
            Ok(size) if size > 0 => {
                input.push_str(&String::from_utf8_lossy(&bytes[..size]));
                if input.contains("MIBOX_HOST_PING") {
                    if serial.write(b"MIBOX_DEVICE_ACK\n").is_ok_and(|n| n == 17) && !acknowledged {
                        note("BIDIRECTIONAL_ACK_SENT");
                        acknowledged = true;
                    }
                    input.clear();
                }
                if input.len() > 4096 {
                    input.clear();
                }
            }
            Ok(_) => {}
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
            Err(error) => note(&format!("SERIAL_READ: {error}")),
        }
        if acknowledged {
            // Give Windows time to read the ACK, then stop queuing announcements
            // after the host closes the COM port.
            thread::sleep(Duration::from_millis(500));
            break;
        }
        thread::sleep(Duration::from_millis(50));
    }
    // Do not flush this legacy tty: deployed revision 3 added that operation
    // and subsequently showed an unexpected reset. Causality is unconfirmed.
    note(if acknowledged {
        "SERIAL_ACK_COMPLETE"
    } else {
        "NO_HOST_PING_OBSERVED"
    });
    Ok(())
}

fn worker() -> io::Result<()> {
    if unsafe { geteuid() } != 0 {
        return Err(io::Error::other("root worker required"));
    }
    fs::create_dir(STATE)?; // Never overwrite a previous experiment or symlink.
    fs::set_permissions(STATE, fs::Permissions::from_mode(0o755))?;
    for attribute in ATTRS {
        let value = fs::read_to_string(format!("{BASE}/{attribute}"))?;
        fs::write(state_file(attribute), value.as_bytes())?;
        fs::set_permissions(state_file(attribute), fs::Permissions::from_mode(0o644))?;
    }
    if fs::read_to_string(state_file("functions"))?.trim() != "ffs"
        || fs::read_to_string(state_file("enable"))?.trim() != "1"
    {
        return Err(io::Error::other(
            "unexpected initial USB state; no change made",
        ));
    }
    let log = File::create(format!("{STATE}/rollback-process.txt"))?;
    fs::set_permissions(
        format!("{STATE}/rollback-process.txt"),
        fs::Permissions::from_mode(0o644),
    )?;
    // This is a separate process, not a thread in the experiment worker.
    // Failure to spawn aborts before any USB writes.
    let mut rollback = Command::new(EXE)
        .arg("--rollback-worker")
        .stdin(Stdio::null())
        .stdout(log.try_clone()?)
        .stderr(log)
        .spawn()?;
    note("ROLLBACK_PROCESS_ARMED: 45 seconds");
    let result = experiment();
    if let Err(error) = &result {
        note(&format!("EXPERIMENT_ERROR: {error}"));
    }
    let restored = restore();
    // The independent worker either retries recovery or sees our verified marker.
    let _ = rollback.wait();
    restored?;
    result
}

fn launch() -> io::Result<()> {
    if !LIVE_EXPERIMENT_ENABLED {
        return Err(io::Error::other(
            "live USB tests suspended: investigate reset/restore evidence first",
        ));
    }
    if fs::symlink_metadata(STATE).is_ok() {
        return Err(io::Error::other(
            "previous test state exists; inspect it before another run",
        ));
    }
    let client = format!(
        "/data/local/tmp/mibox-acm-launch-{}.sock",
        std::process::id()
    );
    let socket = UnixDatagram::bind(&client)?;
    socket.set_read_timeout(Some(Duration::from_secs(3)))?;
    let request = format!(
        "{}\t1\tpppd pty >/dev/null 2>&1; {EXE} --worker\0",
        std::process::id()
    );
    socket.send_to(request.as_bytes(), "/dev/socket/pppoe_wrapper")?;
    let mut ack = [0u8; 128];
    let received = socket.recv(&mut ack);
    fs::remove_file(client)?;
    received?;
    println!("ACM_TEST_LAUNCH_ACKNOWLEDGED; observe USB for 45 seconds");
    Ok(())
}

fn main() -> io::Result<()> {
    match std::env::args().nth(1).as_deref() {
        None => launch(),
        Some("--worker") => worker(),
        Some("--rollback-worker") => {
            if unsafe { geteuid() } != 0 {
                return Err(io::Error::other("root rollback required"));
            }
            thread::sleep(Duration::from_secs(45));
            if fs::read_to_string(format!("{STATE}/restored"))
                .is_ok_and(|s| s.trim() == "USB_STATE_RESTORED")
            {
                println!("Rollback skipped: primary worker already verified restoration");
                Ok(())
            } else {
                restore()
            }
        }
        _ => Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "unsupported mode",
        )),
    }
}
