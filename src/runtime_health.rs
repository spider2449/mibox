//! Read-only snapshot, with bounded reads and explicit unknown values.
use std::fs::File;
use std::io::{self, Read};

const LIMIT: u64 = 65536;

fn read(path: &str) -> io::Result<String> {
    read_from(File::open(path)?)
}

fn read_from(reader: impl Read) -> io::Result<String> {
    let mut bytes = Vec::new();
    reader.take(LIMIT + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > LIMIT {
        return Err(io::Error::other("snapshot input exceeds limit"));
    }
    String::from_utf8(bytes).map_err(|_| io::Error::other("non-UTF8 snapshot input"))
}

fn memory_kib(text: &str, key: &str) -> String {
    let mut matches = text.lines().filter_map(|line| line.strip_prefix(key));
    let Some(value) = matches.next() else {
        return "UNKNOWN".into();
    };
    if matches.next().is_some() {
        return "UNKNOWN".into();
    }
    let fields: Vec<_> = value.split_whitespace().collect();
    if fields.len() != 2 || fields[1] != "kB" || fields[0].parse::<u64>().is_err() {
        return "UNKNOWN".into();
    }
    fields[0].into()
}

fn boot_id(text: &str) -> String {
    let id = text.trim();
    if id.len() == 36
        && id.bytes().enumerate().all(|(i, b)| {
            if matches!(i, 8 | 13 | 18 | 23) {
                b == b'-'
            } else {
                b.is_ascii_digit() || (b'a'..=b'f').contains(&b)
            }
        })
    {
        id.into()
    } else {
        "UNKNOWN".into()
    }
}

fn root_kind(text: &str) -> String {
    let roots: Vec<_> = text
        .lines()
        .filter_map(|line| {
            let fields: Vec<_> = line.split_whitespace().collect();
            if fields.len() >= 6 && fields[1] == "/" {
                Some(fields[2])
            } else {
                None
            }
        })
        .collect();
    if roots.len() == 1 {
        roots[0].into()
    } else {
        "UNKNOWN".into()
    }
}

pub fn snapshot() -> String {
    let memory = read("/proc/meminfo").unwrap_or_default();
    let boot = read("/proc/sys/kernel/random/boot_id").unwrap_or_default();
    let mounts = read("/proc/mounts").unwrap_or_default();
    let pid1 = read("/proc/1/comm")
        .ok()
        .filter(|s| !s.trim().is_empty())
        .map(|s| s.trim().to_owned())
        .unwrap_or_else(|| "UNKNOWN".into());
    let uptime = read("/proc/uptime")
        .ok()
        .and_then(|s| {
            let value = s.split_whitespace().next()?;
            let parsed = value.parse::<f64>().ok()?;
            (parsed.is_finite() && parsed >= 0.0).then(|| value.to_owned())
        })
        .unwrap_or_else(|| "UNKNOWN".into());
    format!("MIBOX_HEALTH_SNAPSHOT_V1\nboot_id={}\nuptime_seconds={}\npid1={}\nroot_fstype={}\nmem_total_kib={}\nmem_free_kib={}\nmem_available_kib={}\n",
        boot_id(&boot), uptime, pid1, root_kind(&mounts),
        memory_kib(&memory, "MemTotal:"), memory_kib(&memory, "MemFree:"),
        memory_kib(&memory, "MemAvailable:"))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn reads_are_bounded_and_require_utf8() {
        assert_eq!(
            read_from(&vec![b'a'; LIMIT as usize][..]).unwrap().len(),
            LIMIT as usize
        );
        assert!(read_from(&vec![b'a'; LIMIT as usize + 1][..]).is_err());
        assert!(read_from(&[255u8][..]).is_err());
    }
    #[test]
    fn old_kernel_memory_has_no_available_estimate() {
        let text = "MemTotal: 877072 kB\nMemFree: 847944 kB\n";
        assert_eq!(memory_kib(text, "MemTotal:"), "877072");
        assert_eq!(memory_kib(text, "MemAvailable:"), "UNKNOWN");
    }
    #[test]
    fn invalid_memory_is_unknown() {
        for text in [
            "",
            "MemFree: -1 kB",
            "MemFree: 1 MB",
            "MemFree: 1 kB junk",
            "MemFree: 18446744073709551616 kB",
            "MemFree: 1 kB\nMemFree: 2 kB",
        ] {
            assert_eq!(memory_kib(text, "MemFree:"), "UNKNOWN");
        }
    }
    #[test]
    fn boot_identity_requires_uuid_shape() {
        assert_eq!(
            boot_id("695ecb4b-717c-4b1b-8e1c-0faaeee26c2b\n"),
            "695ecb4b-717c-4b1b-8e1c-0faaeee26c2b"
        );
        for text in ["", "new-boot", "695ecb4b-717c-4b1b-8e1c-0faaeee26c2z"] {
            assert_eq!(boot_id(text), "UNKNOWN");
        }
    }
    #[test]
    fn root_mount_must_be_unambiguous() {
        assert_eq!(
            root_kind("rootfs / rootfs rw 0 0\nproc /proc proc rw 0 0"),
            "rootfs"
        );
        assert_eq!(root_kind("rootfs /"), "UNKNOWN");
        assert_eq!(
            root_kind("rootfs / rootfs rw 0 0\ntmpfs / tmpfs rw 0 0"),
            "UNKNOWN"
        );
    }
}
