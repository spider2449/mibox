//! Fixed identity-only check for the owner's attached MiBOX1S.
//! Does not install su, change SELinux, or write firmware partitions.
use std::{fs, io, os::unix::net::UnixDatagram, thread, time::Duration};

fn main() -> io::Result<()> {
    let output = "/data/local/tmp/mibox-root-check-v1.txt";
    if fs::symlink_metadata(output).is_ok() {
        return Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            "identity output exists; preserve and inspect it before another run",
        ));
    }
    let client_path = format!(
        "/data/local/tmp/mibox-root-client-{}.sock",
        std::process::id()
    );
    let socket = UnixDatagram::bind(&client_path)?;
    socket.set_read_timeout(Some(Duration::from_secs(2)))?;
    // pppd receives an incomplete option and exits; only the following identity
    // command and scratch-file permission change are requested.
    // libnetutils requires PID<TAB>request-number<TAB>command and a bound
    // client socket for its ACK before dispatching the command handler.
    let message = format!("{}\t1\tpppd pty >/dev/null 2>&1; /system/bin/id > /data/local/tmp/mibox-root-check-v1.txt; /system/bin/chmod 644 /data/local/tmp/mibox-root-check-v1.txt\0", std::process::id());
    socket.send_to(message.as_bytes(), "/dev/socket/pppoe_wrapper")?;
    let mut ack = [0u8; 128];
    let acknowledged = socket.recv(&mut ack);
    fs::remove_file(&client_path)?;
    println!("ACK: {:?}", acknowledged);
    for _ in 0..30 {
        if let Ok(identity) = fs::read_to_string(output) {
            if !identity.trim().is_empty() {
                println!("{}", identity.trim());
                return if identity.starts_with("uid=0(") {
                    println!("MIBOX_ROOT_COMMAND_CONFIRMED");
                    Ok(())
                } else {
                    Err(io::Error::other("command did not report root"))
                };
            }
        }
        thread::sleep(Duration::from_millis(100));
    }
    Err(io::Error::new(
        io::ErrorKind::TimedOut,
        "no identity output; root execution is unconfirmed",
    ))
}
