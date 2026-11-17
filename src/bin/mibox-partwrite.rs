//! Verified write of one 8 MiB boot image to boot1 (plan C3/C4), or restore.
//!
//! mibox-partwrite --target boot1 --image PATH --image-sha256 HEX
//!                 --expect-current-sha256 HEX [--dry-run]
//!
//! Runs as root on the custom RAM system. The only accepted targets are
//! boot1 on the stock Meson6 (sysfs name `boot1`, 179:7, 16384 sectors,
//! writable, not mounted) and, for QEMU rehearsal only, `vdb` when the kernel
//! command line has `mibox.test_partwrite=1`. The target is opened through a
//! private device node created from the verified major:minor.
use std::{fs, io, os::unix::fs::FileTypeExt, os::unix::fs::MetadataExt, path::Path, process};

#[path = "../partwrite.rs"]
mod partwrite;

unsafe extern "C" {
    fn getuid() -> u32;
    fn mknod(path: *const std::os::raw::c_char, mode: u32, dev: u64) -> i32;
}

fn read_trim(path: &str) -> io::Result<String> {
    Ok(fs::read_to_string(path)?.trim().to_owned())
}

fn compatible(value: &[u8]) -> io::Result<bool> {
    Ok(fs::read("/proc/device-tree/compatible")?.split(|b| *b == 0).any(|v| v == value))
}

/// Returns (sysfs name, major, minor) for the requested, allowed target.
fn resolve(target: &str) -> io::Result<(String, u32, u32)> {
    let qemu = compatible(b"linux,dummy-virt")?
        && read_trim("/proc/cmdline")?.split_whitespace().any(|v| v == "mibox.test_partwrite=1");
    let (name, expected) = match target {
        "boot1" if compatible(b"AMLOGIC,8726_MX")? => ("boot1", Some((179, 7))),
        "vdb" if qemu => ("vdb", None),
        _ => return Err(io::Error::other("target not allowed on this platform")),
    };
    let dev = read_trim(&format!("/sys/class/block/{name}/dev"))?;
    let (major, minor) = dev
        .split_once(':')
        .and_then(|(a, b)| Some((a.parse::<u32>().ok()?, b.parse::<u32>().ok()?)))
        .ok_or_else(|| io::Error::other("invalid sysfs dev"))?;
    if let Some(pair) = expected {
        if (major, minor) != pair {
            return Err(io::Error::other(format!("{name} is {major}:{minor}, expected {}:{}", pair.0, pair.1)));
        }
    }
    if read_trim(&format!("/sys/class/block/{name}/size"))? != (partwrite::SIZE / 512).to_string() {
        return Err(io::Error::other("target sector count is not 16384"));
    }
    let ro = format!("/sys/class/block/{name}/ro");
    if Path::new(&ro).exists() && read_trim(&ro)? != "0" {
        return Err(io::Error::other("target is read-only"));
    }
    let mounted = fs::read_to_string("/proc/self/mountinfo")?
        .lines()
        .any(|line| line.split_whitespace().nth(2) == Some(dev.as_str()));
    if mounted {
        return Err(io::Error::other("target is mounted"));
    }
    Ok((name.to_owned(), major, minor))
}

fn node(name: &str, major: u32, minor: u32) -> io::Result<String> {
    let path = format!("/dev/mibox-partwrite-{name}");
    if let Ok(meta) = fs::symlink_metadata(&path) {
        if meta.file_type().is_symlink() || !meta.file_type().is_block_device() {
            return Err(io::Error::other("existing node is not a block device"));
        }
        fs::remove_file(&path)?;
    }
    let c = std::ffi::CString::new(path.clone())?;
    let dev = ((major as u64 & 0xfff) << 8) | (minor as u64 & 0xff) | ((minor as u64 & !0xff) << 12);
    if unsafe { mknod(c.as_ptr(), 0o060600, dev) } != 0 {
        return Err(io::Error::last_os_error());
    }
    let meta = fs::symlink_metadata(&path)?;
    let rdev = meta.rdev();
    let (got_major, got_minor) = (((rdev >> 8) & 0xfff) as u32, ((rdev & 0xff) | ((rdev >> 12) & !0xff)) as u32);
    if !meta.file_type().is_block_device() || (got_major, got_minor) != (major, minor) {
        let _ = fs::remove_file(&path);
        return Err(io::Error::other("created node does not match the target"));
    }
    Ok(path)
}

fn run() -> io::Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut target = None;
    let mut image = None;
    let mut image_sha = None;
    let mut current_sha = None;
    let mut dry_run = false;
    let mut i = 0;
    while i < args.len() {
        let value = || args.get(i + 1).cloned().ok_or_else(|| io::Error::other("missing value"));
        match args[i].as_str() {
            "--target" => { target = Some(value()?); i += 1; }
            "--image" => { image = Some(value()?); i += 1; }
            "--image-sha256" => { image_sha = Some(partwrite::parse_hex(&value()?)?); i += 1; }
            "--expect-current-sha256" => { current_sha = Some(partwrite::parse_hex(&value()?)?); i += 1; }
            "--dry-run" => dry_run = true,
            other => return Err(io::Error::other(format!("unknown argument {other}"))),
        }
        i += 1;
    }
    let (Some(target), Some(image), Some(image_sha), Some(current_sha)) = (target, image, image_sha, current_sha)
    else {
        return Err(io::Error::other(
            "usage: mibox-partwrite --target boot1 --image PATH --image-sha256 HEX --expect-current-sha256 HEX [--dry-run]",
        ));
    };
    if unsafe { getuid() } != 0 {
        return Err(io::Error::other("requires root"));
    }
    if !fs::read_to_string("/etc/os-release")?.lines().any(|l| l == "ID=mibox-custom") {
        return Err(io::Error::other("requires the custom OS marker"));
    }
    let (name, major, minor) = resolve(&target)?;
    let data = fs::read(&image)?;
    let path = node(&name, major, minor)?;
    eprintln!("MIBOX_PARTWRITE_TARGET name={name} dev={major}:{minor} node={path} dry_run={dry_run}");
    let result = partwrite::write_verified(Path::new(&path), &data, &image_sha, &current_sha, true, dry_run, None);
    let _ = fs::remove_file(&path);
    let outcome = result?;
    println!("MIBOX_PARTWRITE_RESULT={outcome:?} target={name} image_sha256={}", partwrite::hex(&image_sha));
    Ok(())
}

fn main() {
    if let Err(error) = run() {
        eprintln!("MIBOX_PARTWRITE_FAILED: {error}");
        process::exit(1);
    }
}
