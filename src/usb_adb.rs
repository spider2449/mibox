//! Opt-in authenticated ADB for a fresh custom PID1 boot, never live Android.
use std::{
    ffi::CString,
    fs,
    io::{self, Write},
    os::{
        raw::{c_char, c_ulong, c_void},
        unix::fs::{MetadataExt, PermissionsExt},
    },
    process::Command,
};

const BASE: &str = "/sys/class/android_usb/android0";
const ATTRIBUTES: &[&str] = &[
    "enable",
    "idVendor",
    "idProduct",
    "bDeviceClass",
    "bDeviceSubClass",
    "bDeviceProtocol",
    "functions",
    "f_ffs/aliases",
    "iManufacturer",
    "iProduct",
    "iSerial",
];
unsafe extern "C" {
    fn mount(
        source: *const c_char,
        target: *const c_char,
        kind: *const c_char,
        flags: c_ulong,
        data: *const c_void,
    ) -> i32;
    fn chown(path: *const c_char, uid: u32, gid: u32) -> i32;
}
pub fn requested() -> bool {
    let flag = fs::read_to_string("/proc/cmdline")
        .is_ok_and(|line| line.split_whitespace().any(|v| v == "mibox.usb_adb=1"));
    let marker = "/etc/mibox-usb-adb.enabled";
    let configured = fs::symlink_metadata(marker).is_ok_and(|entry| {
        entry.is_file() && entry.uid() == 0 && entry.gid() == 0 && entry.mode() & 0o022 == 0
    }) && fs::read(marker)
        .is_ok_and(|value| value == b"MIBOX_AUTHENTICATED_USB_ADB_V1\n");
    flag || configured
}
fn write(name: &str, value: &str) -> io::Result<()> {
    fs::write(format!("{BASE}/{name}"), value)
}
fn mount_virtual(kind: &str, path: &str, data: Option<&str>) -> io::Result<()> {
    let source = CString::new(if kind == "functionfs" { "adb" } else { kind })?;
    let kind = CString::new(kind)?;
    let path = CString::new(path)?;
    let data = data.map(CString::new).transpose()?;
    if unsafe {
        mount(
            source.as_ptr(),
            path.as_ptr(),
            kind.as_ptr(),
            2 | 8,
            data.as_ref()
                .map_or(std::ptr::null(), |v| v.as_ptr().cast()),
        )
    } != 0
    {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}
pub fn start() -> io::Result<u32> {
    if std::process::id() != 1 || !requested() {
        return Err(io::Error::other("USB ADB requires opt-in custom PID1 boot"));
    }
    let compatible = fs::read("/proc/device-tree/compatible")?;
    if !compatible
        .split(|b| *b == 0)
        .any(|v| v == b"AMLOGIC,8726_MX")
    {
        return Err(io::Error::other(
            "USB ADB board guard: not the stock MiBOX Meson6 DT",
        ));
    }
    if fs::metadata("/system/bin/settings").is_ok() {
        return Err(io::Error::other("refuse an Android system root"));
    }
    let keys = fs::symlink_metadata("/adb_keys")?;
    if !keys.is_file()
        || keys.uid() != 0
        || keys.gid() != 0
        || keys.mode() & 0o022 != 0
        || keys.len() == 0
        || keys.len() > 65536
    {
        return Err(io::Error::other(
            "authorized public keys absent or unsafe metadata",
        ));
    }
    for path in ["/sbin/adbd", "/system/bin/sh"] {
        let metadata = fs::symlink_metadata(path)?;
        if !metadata.is_file() || metadata.uid() != 0 || metadata.mode() & 0o022 != 0 {
            return Err(io::Error::other("untrusted console executable"));
        }
    }
    // Read every hardware attribute before any write; unsupported platforms fail untouched.
    let snapshot = ATTRIBUTES
        .iter()
        .map(|name| {
            fs::read_to_string(format!("{BASE}/{name}"))
                .map(|value| (*name, value.trim().to_owned()))
        })
        .collect::<io::Result<Vec<_>>>()?;
    let area =
        crate::android_properties::build(crate::android_properties::AUTHENTICATED_ADB_PROPERTIES)?;
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
    fs::create_dir_all("/dev/pts")?;
    mount_virtual("devpts", "/dev/pts", None)?;
    for node in [
        "/dev/ptmx",
        "/dev/null",
        "/dev/urandom",
        "/dev/random",
        "/dev/tty",
    ] {
        fs::set_permissions(node, fs::Permissions::from_mode(0o666))?;
    }
    for path in ["/dev/usb-ffs", "/dev/usb-ffs/adb"] {
        fs::create_dir_all(path)?;
        fs::set_permissions(path, fs::Permissions::from_mode(0o770))?;
        let path = CString::new(path)?;
        if unsafe { chown(path.as_ptr(), 2000, 2000) } != 0 {
            return Err(io::Error::last_os_error());
        }
    }
    mount_virtual("functionfs", "/dev/usb-ffs/adb", Some("uid=2000,gid=2000"))?;
    let configured = (|| -> io::Result<u32> {
        write("enable", "0")?;
        write("f_ffs/aliases", "adb")?;
        for (name, value) in [
            ("idVendor", "18d1"),
            ("idProduct", "d002"),
            ("bDeviceClass", "0"),
            ("bDeviceSubClass", "0"),
            ("bDeviceProtocol", "0"),
            ("iManufacturer", "Xiaomi"),
            ("iProduct", "MiBOX1S Custom Linux"),
            ("iSerial", "248243005297"),
            ("functions", "adb"),
        ] {
            write(name, value)?;
        }
        write("enable", "1")?;
        if fs::read_to_string(format!("{BASE}/enable"))?.trim() != "1" {
            return Err(io::Error::other("USB enable did not read back"));
        }
        // No TCP fallback: do not spawn unless the mounted FunctionFS endpoint exists.
        if !fs::metadata("/dev/usb-ffs/adb/ep0")?.is_file() {
            return Err(io::Error::other("FunctionFS ep0 absent"));
        }
        let child = Command::new("/sbin/adbd").arg("recovery").spawn()?;
        let pid = child.id();
        drop(child); // PID1's generic reaper owns any eventual daemon exit.
        Ok(pid)
    })();
    if let Err(error) = configured {
        let _ = write("enable", "0");
        let mut errors = Vec::new();
        for (name, value) in snapshot.iter().filter(|(name, _)| *name != "enable") {
            if let Err(failure) = write(name, value) {
                errors.push(format!("{name}: {failure}"));
            }
        }
        if let Some((_, enabled)) = snapshot.iter().find(|(name, _)| *name == "enable") {
            if let Err(failure) = write("enable", enabled) {
                errors.push(failure.to_string());
            }
        }
        return Err(io::Error::other(format!(
            "{error}; USB restoration errors={errors:?}"
        )));
    }
    configured
}
