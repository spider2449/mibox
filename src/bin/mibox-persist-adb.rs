//! Fixed installer/rollback for the owner's stock post-boot USB ADB hook.
use std::ffi::CString;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::os::fd::AsRawFd;
use std::os::raw::{c_char, c_int, c_ulong, c_void};
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::os::unix::net::UnixDatagram;
use std::process::{Child, Command, Stdio};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const TARGET: &str = "/system/etc/init.post-boot.sh";
const STATE: &str = "/data/local/tmp/mibox-adb-persistence-v1";
const EXE: &str = "/data/local/tmp/mibox-persist-adb";
const ORIGINAL: &[u8] = include_bytes!("../../assets/adb/init.post-boot.original.sh");
const ADDITION: &[u8] = include_bytes!("../../assets/adb/keep-usb-adb.sh");
const PREVIOUS_ADDITION: &[u8] = include_bytes!("../../assets/adb/keep-usb-adb-v1.sh");
const V2_ADDITION: &[u8] = include_bytes!("../../assets/adb/keep-usb-adb-v2.sh");

unsafe extern "C" {
    fn geteuid() -> u32;
    fn mount(
        source: *const c_char,
        target: *const c_char,
        kind: *const c_char,
        flags: c_ulong,
        data: *const c_void,
    ) -> c_int;
    fn getxattr(path: *const c_char, name: *const c_char, value: *mut c_void, size: usize)
        -> isize;
    fn setxattr(
        path: *const c_char,
        name: *const c_char,
        value: *const c_void,
        size: usize,
        flags: c_int,
    ) -> c_int;
    fn chown(path: *const c_char, uid: u32, gid: u32) -> c_int;
    fn ioctl(fd: c_int, request: c_ulong, ...) -> c_int;
}

fn candidate() -> Vec<u8> {
    let mut data = ORIGINAL.to_vec();
    data.extend_from_slice(ADDITION);
    data
}
fn label(path: &str) -> io::Result<Vec<u8>> {
    let path = CString::new(path)?;
    let name = CString::new("security.selinux")?;
    let mut bytes = [0u8; 256];
    let size = unsafe {
        getxattr(
            path.as_ptr(),
            name.as_ptr(),
            bytes.as_mut_ptr().cast(),
            bytes.len(),
        )
    };
    if size < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(bytes[..size as usize].to_vec())
}
fn remount(readonly: bool) -> io::Result<()> {
    let source = CString::new("/dev/block/system1")?;
    let target = CString::new("/system")?;
    let kind = CString::new("ext4")?;
    let flags: c_ulong = 32 | 2048 | 2097152 | if readonly { 1 } else { 0 };
    let native_result = unsafe {
        mount(
            source.as_ptr(),
            target.as_ptr(),
            kind.as_ptr(),
            flags,
            std::ptr::null(),
        )
    };
    let native_error = if native_result < 0 {
        io::Error::last_os_error().to_string()
    } else {
        "none".to_owned()
    };
    if native_result == 0 && system_is_readonly()? == readonly {
        return Ok(());
    }
    let option = if readonly { "remount,ro" } else { "remount,rw" };
    let result = Command::new("/system/xbin/busybox")
        .args([
            "mount",
            "-t",
            "ext4",
            "-o",
            option,
            "/dev/block/system1",
            "/system",
        ])
        .output()?;
    if result.status.success() && system_is_readonly()? == readonly {
        Ok(())
    } else {
        let status = fs::read_to_string("/proc/self/status").unwrap_or_default();
        let credentials = status
            .lines()
            .filter(|line| {
                line.starts_with("Uid:")
                    || line.starts_with("Gid:")
                    || line.starts_with("CapEff:")
                    || line.starts_with("CapBnd:")
            })
            .collect::<Vec<_>>()
            .join("; ");
        let context = fs::read_to_string("/proc/self/attr/current").unwrap_or_default();
        Err(io::Error::other(format!("mount did not establish requested mode; syscall={native_result} ({native_error}); tool={:?}; stdout={}; stderr={}; {credentials}; context={context}", result.status, String::from_utf8_lossy(&result.stdout),String::from_utf8_lossy(&result.stderr))))
    }
}
fn system_is_readonly() -> io::Result<bool> {
    for line in fs::read_to_string("/proc/mounts")?.lines() {
        let fields: Vec<_> = line.split_whitespace().collect();
        if fields.len() >= 4 && fields[1] == "/system" {
            if fields[0] != "/dev/block/system1" || fields[2] != "ext4" {
                return Err(io::Error::other(
                    "unexpected system mount; refusing modification",
                ));
            }
            return Ok(fields[3].split(',').any(|flag| flag == "ro"));
        }
    }
    Err(io::Error::other("system mount absent"))
}
fn verify_metadata(path: &str, expected_label: &[u8]) -> io::Result<()> {
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.is_file()
        || metadata.uid() != 0
        || metadata.gid() != 0
        || metadata.mode() & 0o7777 != 0o644
        || label(path)? != expected_label
    {
        return Err(io::Error::other("script owner/mode/SELinux label mismatch"));
    }
    Ok(())
}
fn set_partition_readonly(readonly: bool) -> io::Result<()> {
    let block = File::open("/dev/block/system1")?;
    let mut value: c_int = if readonly { 1 } else { 0 };
    if unsafe {
        ioctl(
            block.as_raw_fd(),
            0x125d as c_ulong,
            &mut value as *mut c_int,
        )
    } != 0
    {
        return Err(io::Error::last_os_error());
    }
    if fs::read_to_string("/sys/class/block/system1/ro")?.trim() != if readonly { "1" } else { "0" }
    {
        return Err(io::Error::other("block read-only flag did not verify"));
    }
    Ok(())
}
struct StorageGuard {
    child: Option<Child>,
}
impl StorageGuard {
    fn begin() -> io::Result<Self> {
        if fs::read_to_string("/sys/class/block/system1/ro")?.trim() != "1" {
            return Err(io::Error::other("unexpected partition read-only flag"));
        }
        let child = Command::new(EXE)
            .arg("--storage-guard")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()?;
        let guard = Self { child: Some(child) };
        set_partition_readonly(false)?;
        Ok(guard)
    }
    fn restore(&mut self) -> io::Result<()> {
        if !system_is_readonly()? {
            remount(true)?;
        }
        set_partition_readonly(true)?;
        if let Some(mut child) = self.child.take() {
            let _ = child.wait();
        }
        Ok(())
    }
}
impl Drop for StorageGuard {
    fn drop(&mut self) {
        let _ = self.restore();
    }
}
fn atomic_replace(bytes: &[u8], original_label: &[u8], job: &str) -> io::Result<()> {
    let temporary = format!("/system/etc/.mibox-adb-{job}.tmp");
    let original_readonly = system_is_readonly()?;
    if !original_readonly {
        return Err(io::Error::other("system was unexpectedly writable"));
    }
    let mut storage_guard = StorageGuard::begin()?;
    remount(false).map_err(|e| io::Error::other(format!("remount /system writable: {e}")))?;
    let changed = (|| -> io::Result<()> {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)
            .map_err(|e| io::Error::other(format!("create candidate script: {e}")))?;
        file.write_all(bytes)?;
        file.sync_all()?;
        fs::set_permissions(&temporary, fs::Permissions::from_mode(0o644))?;
        let path = CString::new(temporary.as_str())?;
        if unsafe { chown(path.as_ptr(), 0, 0) } != 0 {
            return Err(io::Error::last_os_error());
        }
        if label(&temporary)? != original_label {
            let name = CString::new("security.selinux")?;
            if unsafe {
                setxattr(
                    path.as_ptr(),
                    name.as_ptr(),
                    original_label.as_ptr().cast(),
                    original_label.len(),
                    0,
                )
            } != 0
            {
                return Err(io::Error::last_os_error());
            }
        }
        verify_metadata(&temporary, original_label)?;
        if fs::read(&temporary)? != bytes {
            return Err(io::Error::other("temporary script readback mismatch"));
        }
        fs::rename(&temporary, TARGET)?;
        File::open("/system/etc")?.sync_all()?;
        Ok(())
    })();
    let readonly_result = remount(true);
    let storage_result = storage_guard.restore();
    readonly_result.map_err(|e| io::Error::other(format!("restore /system read-only: {e}")))?;
    storage_result?;
    changed?;
    if !system_is_readonly()? {
        return Err(io::Error::other("system was not restored read-only"));
    }
    if fs::read(TARGET)? != bytes {
        return Err(io::Error::other("installed script readback mismatch"));
    }
    verify_metadata(TARGET, original_label)
}
fn run(program: &str, args: &[&str]) -> io::Result<String> {
    // Stock Android's settings wrapper has no executable shebang. Interactive
    // sh falls back automatically; Command/execve requires an explicit shell.
    let result = if program == "/system/bin/settings" {
        Command::new("/system/bin/sh")
            .arg(program)
            .args(args)
            .output()
            .map_err(|e| io::Error::other(format!("execute settings wrapper with sh: {e}")))?
    } else {
        Command::new(program)
            .args(args)
            .output()
            .map_err(|e| io::Error::other(format!("execute {program}: {e}")))?
    };
    if !result.status.success() {
        return Err(io::Error::other(format!(
            "{program} failed: {}",
            String::from_utf8_lossy(&result.stderr)
        )));
    }
    Ok(String::from_utf8_lossy(&result.stdout).trim().to_owned())
}
fn change(rollback: bool, job: &str) -> io::Result<()> {
    if unsafe { geteuid() } != 0 {
        return Err(io::Error::other("root worker required"));
    }
    let current = fs::read(TARGET)?;
    let patched = candidate();
    let original_label =
        label(TARGET).map_err(|e| io::Error::other(format!("read original SELinux label: {e}")))?;
    if original_label.strip_suffix(&[0]).unwrap_or(&original_label) != b"u:object_r:system_file:s0"
    {
        return Err(io::Error::other("unexpected stock script label"));
    }
    verify_metadata(TARGET, &original_label)
        .map_err(|e| io::Error::other(format!("verify original metadata: {e}")))?;
    let mut previous = ORIGINAL.to_vec();
    previous.extend_from_slice(PREVIOUS_ADDITION);
    let mut v2 = ORIGINAL.to_vec();
    v2.extend_from_slice(V2_ADDITION);
    if current != ORIGINAL && current != patched && current != previous && current != v2 {
        return Err(io::Error::other("stock script differs from pinned backup"));
    }
    if rollback {
        if fs::read(format!("{STATE}/original.sh"))? != ORIGINAL {
            return Err(io::Error::other("saved backup mismatch"));
        }
        if current != ORIGINAL {
            atomic_replace(ORIGINAL, &original_label, job)?;
        }
        return Ok(());
    }
    // Confirm access to SettingsProvider before modifying any system file.
    let before = run("/system/bin/settings", &["get", "global", "adb_enabled"])?;
    if current == ORIGINAL {
        match fs::create_dir(STATE) {
            Ok(()) => {}
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {
                let meta = fs::symlink_metadata(STATE)?;
                if !meta.is_dir() || meta.uid() != 0 {
                    return Err(io::Error::other("existing backup directory is not trusted"));
                }
            }
            Err(e) => return Err(io::Error::other(format!("create backup directory: {e}"))),
        }
        fs::set_permissions(STATE, fs::Permissions::from_mode(0o755))?;
        for (name, bytes) in [
            ("original.sh", ORIGINAL),
            ("candidate.sh", patched.as_slice()),
            ("selinux-label.bin", original_label.as_slice()),
            ("adb-enabled-before.txt", before.as_bytes()),
        ] {
            let path = format!("{STATE}/{name}");
            if fs::symlink_metadata(&path).is_ok() {
                let meta = fs::symlink_metadata(&path)?;
                let saved = fs::read(&path)?;
                let known_candidate = name == "candidate.sh"
                    && (saved == previous || saved == v2 || saved == patched);
                if !meta.is_file() || meta.uid() != 0 || (saved != bytes && !known_candidate) {
                    return Err(io::Error::other(format!("existing backup differs: {name}")));
                }
                continue;
            }
            let mut file = OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&path)?;
            file.write_all(bytes)?;
            file.sync_all()?;
            fs::set_permissions(path, fs::Permissions::from_mode(0o644))?;
        }
    }
    if current != patched {
        atomic_replace(&patched, &original_label, job)?;
    }
    run(
        "/system/bin/settings",
        &["put", "global", "adb_enabled", "1"],
    )?;
    run("/system/bin/setprop", &["persist.sys.usb.config", "adb"])?;
    if run("/system/bin/settings", &["get", "global", "adb_enabled"])? != "1"
        || run("/system/bin/getprop", &["persist.sys.usb.config"])? != "adb"
    {
        return Err(io::Error::other("current ADB settings did not verify"));
    }
    Ok(())
}
fn launch(rollback: bool) -> io::Result<()> {
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(io::Error::other)?
        .as_millis();
    let job = format!("{}-{stamp}", std::process::id());
    let client = format!("/data/local/tmp/mibox-adb-job-{job}.sock");
    let socket = UnixDatagram::bind(&client)?;
    socket.set_read_timeout(Some(Duration::from_secs(3)))?;
    let mode = if rollback {
        "--worker-rollback"
    } else {
        "--worker-install"
    };
    let packet = format!(
        "{}\t1\tpppd pty >/dev/null 2>&1; {EXE} {mode} {job}\0",
        std::process::id()
    );
    socket.send_to(packet.as_bytes(), "/dev/socket/pppoe_wrapper")?;
    let mut ack = [0u8; 128];
    let received = socket.recv(&mut ack);
    fs::remove_file(client)?;
    received?;
    let path = format!("/data/local/tmp/mibox-adb-job-{job}.txt");
    for _ in 0..600 {
        if let Ok(result) = fs::read_to_string(&path) {
            if result.contains("MIBOX_ADB_WORKER_") {
                println!("{}", result.trim());
                return if result.contains("MIBOX_ADB_WORKER_OK") {
                    Ok(())
                } else {
                    Err(io::Error::other("root worker failed"))
                };
            }
        }
        thread::sleep(Duration::from_millis(100));
    }
    Err(io::Error::new(
        io::ErrorKind::TimedOut,
        "installer result not received",
    ))
}
fn main() -> io::Result<()> {
    let args: Vec<_> = std::env::args().skip(1).collect();
    match args.as_slice() {
        [mode] if mode == "--storage-guard" => {
            if unsafe { geteuid() } != 0 {
                return Err(io::Error::other("root guard required"));
            }
            thread::sleep(Duration::from_secs(15));
            if !system_is_readonly()? {
                remount(true)?;
            }
            set_partition_readonly(true)?;
            Ok(())
        }
        [] => launch(false),
        [mode] if mode == "--rollback" => launch(true),
        [mode, job]
            if (mode == "--worker-install" || mode == "--worker-rollback")
                && job.len() < 64
                && job.bytes().all(|b| b.is_ascii_digit() || b == b'-') =>
        {
            let result = change(mode == "--worker-rollback", job);
            let text = match &result {
                Ok(()) => format!("MIBOX_ADB_WORKER_OK {mode} job={job}\n"),
                Err(e) => format!("MIBOX_ADB_WORKER_ERROR {mode} job={job}: {e}\n"),
            };
            let path = format!("/data/local/tmp/mibox-adb-job-{job}.txt");
            fs::write(&path, text)?;
            fs::set_permissions(path, fs::Permissions::from_mode(0o644))?;
            result
        }
        _ => Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "unsupported installer arguments",
        )),
    }
}
