//! Opt-in ACM setup using the stock MiBOX1S recipe tested from Android.
//! Generic QEMU and non-PID1 runs do not configure USB.
use std::{fs, io};

const BASE: &str = "/sys/class/android_usb/android0";
const ATTRIBUTES: &[&str] = &[
    "enable",
    "functions",
    "f_acm/instances",
    "idVendor",
    "idProduct",
    "bDeviceClass",
    "bDeviceSubClass",
    "bDeviceProtocol",
];

fn write(attribute: &str, value: &str) -> io::Result<()> {
    fs::write(format!("{BASE}/{attribute}"), value.as_bytes())
}

pub fn requested() -> bool {
    fs::read_to_string("/proc/cmdline").is_ok_and(|line| {
        line.split_whitespace()
            .any(|word| word == "mibox.usb_acm=1")
    })
}

pub fn enable() -> io::Result<&'static str> {
    // Complete the snapshot before the first write. Missing/unsupported gadget
    // drivers therefore leave the platform unchanged.
    let snapshot: Vec<(&str, String)> = ATTRIBUTES
        .iter()
        .map(|attribute| {
            fs::read_to_string(format!("{BASE}/{attribute}"))
                .map(|value| (*attribute, value.trim().to_owned()))
        })
        .collect::<io::Result<_>>()?;
    let configured = (|| -> io::Result<()> {
        write("enable", "0")?;
        write("f_acm/instances", "1")?;
        write("idVendor", "18d1")?;
        write("idProduct", "4e41")?;
        write("bDeviceClass", "02")?;
        write("bDeviceSubClass", "02")?;
        write("bDeviceProtocol", "01")?;
        write("functions", "acm")?;
        write("enable", "1")?;
        for (attribute, expected) in [
            ("functions", "acm"),
            ("enable", "1"),
            ("f_acm/instances", "1"),
        ] {
            if fs::read_to_string(format!("{BASE}/{attribute}"))?.trim() != expected {
                return Err(io::Error::other(format!(
                    "USB readback mismatch: {attribute}"
                )));
            }
        }
        fs::metadata("/dev/ttyGS0")?;
        Ok(())
    })();
    if let Err(error) = configured {
        let mut rollback_errors = Vec::new();
        if let Err(failure) = write("enable", "0") {
            rollback_errors.push(failure.to_string());
        }
        for (attribute, value) in snapshot.iter().filter(|(name, _)| *name != "enable") {
            if let Err(failure) = write(attribute, value) {
                rollback_errors.push(format!("{attribute}: {failure}"));
            }
        }
        if let Some((_, enable)) = snapshot.iter().find(|(name, _)| *name == "enable") {
            if let Err(failure) = write("enable", enable) {
                rollback_errors.push(failure.to_string());
            }
        }
        return Err(io::Error::other(format!(
            "{error}; rollback errors: {}",
            rollback_errors.join("; ")
        )));
    }
    Ok("/dev/ttyGS0")
}
