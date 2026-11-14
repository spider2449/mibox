//! Runs as an ordinary process under Android. No device writes or PID1 setup.
use std::{fs, process, thread, time::Duration};

fn main() {
    // This binary is not an init implementation: exiting as PID1 would panic Linux.
    if process::id() == 1 {
        loop {
            thread::sleep(Duration::from_secs(3600));
        }
    }
    println!("mibox-probe {}", env!("CARGO_PKG_VERSION"));
    println!("arch: {}", std::env::consts::ARCH);
    println!("pid: {}", process::id());
    for path in [
        "/proc/version",
        "/proc/self/status",
        "/proc/cpuinfo",
        "/proc/meminfo",
        "/proc/filesystems",
        "/proc/partitions",
        "/proc/modules",
        "/proc/mounts",
        "/sys/class/tty/ttyS0/dev",
        "/sys/class/tty/ttyS1/dev",
        "/sys/class/tty/ttyGS0/dev",
    ] {
        println!("\n--- {path} ---");
        match fs::read_to_string(path) {
            Ok(text) => println!("{}", text.trim_end()),
            Err(error) => println!("unavailable: {error}"),
        }
    }
    println!("\nMIBOX_PROBE_OK");
}
