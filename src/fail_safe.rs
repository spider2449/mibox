//! A32-style startup fail-safe for the RAM PID1.
//!
//! MiBOX has no fastboot. Its installed `preboot` USB window (`update 10000;`)
//! is passed on every restart, so a normal restart is the route back to the
//! C003 USB loader when a host is attached. Without a host the window is
//! expected to expire and continue the existing boot path; that case is not
//! yet physically observed. Every fatal PID1 fault therefore requests a
//! bounded sync followed by a normal restart instead of holding forever.
use std::{
    os::raw::c_int,
    sync::mpsc,
    thread,
    time::Duration,
};

/// USB function setup must finish within this time after PID1 starts it.
/// A missing USB host is not a failure: setup does not wait for enumeration.
pub const SETUP_DEADLINE: Duration = Duration::from_secs(60);
/// A stuck eMMC must not stop the restart that may repair it (A32 uses 15 s).
const SYNC_LIMIT: Duration = Duration::from_secs(15);
const LINUX_REBOOT_CMD_RESTART: c_int = 0x0123_4567;

unsafe extern "C" {
    fn sync();
    fn reboot(command: c_int) -> c_int;
}

/// Build-time fault injection for RAM test candidates only. Normal builds
/// leave `MIBOX_FAULT` unset; never flash an image built with it.
pub fn injected() -> Option<&'static str> {
    option_env!("MIBOX_FAULT").filter(|value| matches!(*value, "panic" | "usb" | "hang" | "kpanic"))
}

/// Never returns. Logs the reason, syncs with a bound and restarts normally.
pub fn restart(reason: &str) -> ! {
    eprintln!("MIBOX_FAIL_SAFE_RESTART reason={reason}");
    let (done, finished) = mpsc::channel();
    let _ = thread::Builder::new().spawn(move || {
        unsafe { sync() };
        let _ = done.send(());
    });
    if finished.recv_timeout(SYNC_LIMIT).is_err() {
        eprintln!("MIBOX_FAIL_SAFE_SYNC_TIMEOUT");
    }
    let result = unsafe { reboot(LINUX_REBOOT_CMD_RESTART) };
    eprintln!(
        "MIBOX_FAIL_SAFE_RESTART_FAILED result={result} error={}",
        std::io::Error::last_os_error()
    );
    // Last resort, as in A32: the kernel's own immediate reboot request.
    let _ = std::fs::write("/proc/sysrq-trigger", b"b");
    loop {
        thread::sleep(Duration::from_secs(1));
    }
}
