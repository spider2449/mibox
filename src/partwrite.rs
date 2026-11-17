//! Verified whole-partition write for plan C3/C4 (and its restore).
//!
//! One fixed-size image replaces one target only when the target's current
//! content has the hash the operator names, so a write can never replace
//! unexpected bytes. After writing: fsync, block-cache flush, and a complete
//! re-read whose hash must equal the image. The same call restores a backup.
use std::{
    fs::{File, OpenOptions},
    io::{self, Read, Write},
    os::{fd::AsRawFd, raw::c_int, unix::fs::OpenOptionsExt},
    path::Path,
};

pub const SIZE: usize = 8 * 1024 * 1024;
const O_SYNC: c_int = 0o4010000;
const O_EXCL: c_int = 0o200;
const BLKFLSBUF: u32 = 0x1261;

unsafe extern "C" {
    fn ioctl(fd: c_int, request: u32, ...) -> c_int;
}

/// Minimal SHA-256 (FIPS 180-4); unit-tested against standard vectors.
pub struct Sha256 {
    state: [u32; 8],
    buffer: Vec<u8>,
    length: u64,
}

const K: [u32; 64] = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

impl Sha256 {
    pub fn new() -> Self {
        Sha256 {
            state: [
                0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab,
                0x5be0cd19,
            ],
            buffer: Vec::with_capacity(64),
            length: 0,
        }
    }

    fn block(&mut self, chunk: &[u8]) {
        let mut w = [0u32; 64];
        for i in 0..16 {
            w[i] = u32::from_be_bytes([chunk[4 * i], chunk[4 * i + 1], chunk[4 * i + 2], chunk[4 * i + 3]]);
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16].wrapping_add(s0).wrapping_add(w[i - 7]).wrapping_add(s1);
        }
        let [mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut h] = self.state;
        for i in 0..64 {
            let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let ch = (e & f) ^ (!e & g);
            let t1 = h.wrapping_add(s1).wrapping_add(ch).wrapping_add(K[i]).wrapping_add(w[i]);
            let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let maj = (a & b) ^ (a & c) ^ (b & c);
            let t2 = s0.wrapping_add(maj);
            h = g;
            g = f;
            f = e;
            e = d.wrapping_add(t1);
            d = c;
            c = b;
            b = a;
            a = t1.wrapping_add(t2);
        }
        for (s, v) in self.state.iter_mut().zip([a, b, c, d, e, f, g, h]) {
            *s = s.wrapping_add(v);
        }
    }

    pub fn update(&mut self, mut data: &[u8]) {
        self.length += data.len() as u64;
        if !self.buffer.is_empty() {
            let take = (64 - self.buffer.len()).min(data.len());
            self.buffer.extend_from_slice(&data[..take]);
            data = &data[take..];
            if self.buffer.len() == 64 {
                let block = std::mem::take(&mut self.buffer);
                self.block(&block);
            }
        }
        while data.len() >= 64 {
            self.block(&data[..64]);
            data = &data[64..];
        }
        self.buffer.extend_from_slice(data);
    }

    pub fn finish(mut self) -> [u8; 32] {
        let bits = self.length.wrapping_mul(8);
        let mut tail = std::mem::take(&mut self.buffer);
        tail.push(0x80);
        while tail.len() % 64 != 56 {
            tail.push(0);
        }
        tail.extend_from_slice(&bits.to_be_bytes());
        for chunk in tail.chunks(64) {
            self.block(chunk);
        }
        let mut out = [0u8; 32];
        for (i, v) in self.state.iter().enumerate() {
            out[4 * i..4 * i + 4].copy_from_slice(&v.to_be_bytes());
        }
        out
    }
}

pub fn sha256(data: &[u8]) -> [u8; 32] {
    let mut h = Sha256::new();
    h.update(data);
    h.finish()
}

pub fn hex(digest: &[u8; 32]) -> String {
    digest.iter().map(|b| format!("{b:02x}")).collect()
}

pub fn parse_hex(text: &str) -> io::Result<[u8; 32]> {
    if text.len() != 64 || !text.bytes().all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase()) {
        return Err(io::Error::other("expected 64 lowercase hex characters"));
    }
    let mut out = [0u8; 32];
    for i in 0..32 {
        out[i] = u8::from_str_radix(&text[2 * i..2 * i + 2], 16).map_err(io::Error::other)?;
    }
    Ok(out)
}

/// Reads exactly SIZE bytes and requires end of data after them.
fn read_exact_size(path: &Path) -> io::Result<Vec<u8>> {
    let mut file = File::open(path)?;
    let mut data = vec![0u8; SIZE];
    file.read_exact(&mut data)?;
    let mut extra = [0u8; 1];
    if file.read(&mut extra)? != 0 {
        return Err(io::Error::other("target is larger than the image size"));
    }
    Ok(data)
}

#[derive(Debug, PartialEq)]
pub enum Outcome {
    DryRunVerified,
    AlreadyInstalled,
    Written,
}

/// `block_device` adds O_EXCL (refused while the kernel has it mounted) and a
/// BLKFLSBUF cache flush before the re-read. `after_write` is a test hook.
pub fn write_verified(
    target: &Path,
    image: &[u8],
    image_sha256: &[u8; 32],
    expect_current_sha256: &[u8; 32],
    block_device: bool,
    dry_run: bool,
    after_write: Option<&dyn Fn(&Path)>,
) -> io::Result<Outcome> {
    if image.len() != SIZE {
        return Err(io::Error::other(format!("image is {} bytes, expected {SIZE}", image.len())));
    }
    if &sha256(image) != image_sha256 {
        return Err(io::Error::other("image SHA256 differs from --image-sha256"));
    }
    let current = sha256(&read_exact_size(target)?);
    if &current == image_sha256 {
        eprintln!("MIBOX_PARTWRITE_CURRENT={}", hex(&current));
        return Ok(Outcome::AlreadyInstalled);
    }
    if &current != expect_current_sha256 {
        return Err(io::Error::other(format!(
            "target content {} differs from --expect-current-sha256; refusing",
            hex(&current)
        )));
    }
    eprintln!("MIBOX_PARTWRITE_CURRENT_VERIFIED={}", hex(&current));
    if dry_run {
        return Ok(Outcome::DryRunVerified);
    }
    {
        let mut options = OpenOptions::new();
        options.write(true).custom_flags(O_SYNC | if block_device { O_EXCL } else { 0 });
        let mut file = options.open(target)?;
        eprintln!("MIBOX_PARTWRITE_WRITING bytes={SIZE}");
        file.write_all(image)?;
        file.sync_all()?;
        if block_device && unsafe { ioctl(file.as_raw_fd(), BLKFLSBUF) } != 0 {
            return Err(io::Error::last_os_error());
        }
    }
    if let Some(hook) = after_write {
        hook(target);
    }
    let readback = sha256(&read_exact_size(target)?);
    if &readback != image_sha256 {
        return Err(io::Error::other(format!(
            "READBACK MISMATCH: target now {}; restore from backup",
            hex(&readback)
        )));
    }
    eprintln!("MIBOX_PARTWRITE_READBACK_VERIFIED={}", hex(&readback));
    Ok(Outcome::Written)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn sha256_vectors() {
        assert_eq!(hex(&sha256(b"")), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
        assert_eq!(hex(&sha256(b"abc")), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
        assert_eq!(
            hex(&sha256(b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        );
        let million = vec![b'a'; 1_000_000];
        let mut split = Sha256::new();
        for part in million.chunks(997) {
            split.update(part);
        }
        assert_eq!(hex(&split.finish()), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0");
    }

    struct Case {
        dir: std::path::PathBuf,
        target: std::path::PathBuf,
        old: Vec<u8>,
        new: Vec<u8>,
    }

    fn case(name: &str) -> Case {
        let dir = std::env::temp_dir().join(format!("mibox-partwrite-{}-{name}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let old: Vec<u8> = (0..SIZE).map(|i| (i * 7 % 251) as u8).collect();
        let new: Vec<u8> = (0..SIZE).map(|i| (i * 13 % 241) as u8).collect();
        let target = dir.join("target.img");
        fs::write(&target, &old).unwrap();
        Case { dir, target, old, new }
    }

    #[test]
    fn writes_and_verifies() {
        let c = case("ok");
        let r = write_verified(&c.target, &c.new, &sha256(&c.new), &sha256(&c.old), false, false, None);
        assert_eq!(r.unwrap(), Outcome::Written);
        assert_eq!(fs::read(&c.target).unwrap(), c.new);
        // Restore is the same operation in the other direction.
        let r = write_verified(&c.target, &c.old, &sha256(&c.old), &sha256(&c.new), false, false, None);
        assert_eq!(r.unwrap(), Outcome::Written);
        assert_eq!(fs::read(&c.target).unwrap(), c.old);
        fs::remove_dir_all(c.dir).unwrap();
    }

    #[test]
    fn refusals_leave_target_unchanged() {
        let c = case("refuse");
        let wrong = sha256(b"not it");
        let short = &c.new[..SIZE - 1];
        let checks: Vec<io::Result<Outcome>> = vec![
            write_verified(&c.target, short, &sha256(short), &sha256(&c.old), false, false, None),
            write_verified(&c.target, &c.new, &wrong, &sha256(&c.old), false, false, None),
            write_verified(&c.target, &c.new, &sha256(&c.new), &wrong, false, false, None),
        ];
        for r in checks {
            assert!(r.is_err());
            assert_eq!(fs::read(&c.target).unwrap(), c.old);
        }
        assert_eq!(
            write_verified(&c.target, &c.new, &sha256(&c.new), &sha256(&c.old), false, true, None).unwrap(),
            Outcome::DryRunVerified
        );
        assert_eq!(fs::read(&c.target).unwrap(), c.old);
        fs::remove_dir_all(c.dir).unwrap();
    }

    #[test]
    fn wrong_target_size_refused() {
        let c = case("size");
        fs::write(&c.target, &c.old[..SIZE - 512]).unwrap();
        assert!(write_verified(&c.target, &c.new, &sha256(&c.new), &sha256(&c.old), false, false, None).is_err());
        let mut big = c.old.clone();
        big.extend_from_slice(&[0; 512]);
        fs::write(&c.target, &big).unwrap();
        assert!(write_verified(&c.target, &c.new, &sha256(&c.new), &sha256(&c.old), false, false, None).is_err());
        assert_eq!(fs::read(&c.target).unwrap(), big);
        fs::remove_dir_all(c.dir).unwrap();
    }

    #[test]
    fn already_installed_is_not_rewritten() {
        let c = case("same");
        fs::write(&c.target, &c.new).unwrap();
        let r = write_verified(&c.target, &c.new, &sha256(&c.new), &sha256(&c.old), false, false, None);
        assert_eq!(r.unwrap(), Outcome::AlreadyInstalled);
        fs::remove_dir_all(c.dir).unwrap();
    }

    #[test]
    fn readback_corruption_is_reported() {
        let c = case("corrupt");
        let corrupt = |p: &Path| {
            let mut d = fs::read(p).unwrap();
            d[SIZE / 2] ^= 1;
            fs::write(p, d).unwrap();
        };
        let r = write_verified(&c.target, &c.new, &sha256(&c.new), &sha256(&c.old), false, false, Some(&corrupt));
        let message = r.unwrap_err().to_string();
        assert!(message.contains("READBACK MISMATCH"), "{message}");
        // A retry from the now-unknown content must be refused unless named.
        assert!(write_verified(&c.target, &c.new, &sha256(&c.new), &sha256(&c.old), false, false, None).is_err());
        fs::remove_dir_all(c.dir).unwrap();
    }

    #[test]
    fn hex_parsing_is_strict() {
        assert!(parse_hex("ABCD").is_err());
        assert!(parse_hex(&"A".repeat(64)).is_err());
        assert!(parse_hex(&"a".repeat(64)).is_ok());
    }
}
