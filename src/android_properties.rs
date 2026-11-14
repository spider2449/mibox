//! Read-only Android 4.4 property-area ABI, validated against stock adbd in QEMU.
use std::io;

pub const AUTHENTICATED_ADB_PROPERTIES: &[(&str, &str)] = &[
    ("ro.adb.secure", "1"),
    ("ro.secure", "1"),
    ("ro.debuggable", "0"),
    ("ro.product.name", "casablanca_icntv"),
    ("ro.product.model", "MiBOX1S"),
    ("ro.product.device", "casablanca"),
    ("service.adb.tcp.port", "0"),
    ("persist.adb.tcp.port", "0"),
];

pub fn build(values: &[(&str, &str)]) -> io::Result<Vec<u8>> {
    let mut area = vec![0u8; 128 * 1024];
    area[8..12].copy_from_slice(&0x504f5250u32.to_le_bytes());
    area[12..16].copy_from_slice(&0xfc6ed0abu32.to_le_bytes());
    let mut used = 20;
    for (name, value) in values {
        add_property(&mut area, &mut used, name, value)?;
    }
    area[..4].copy_from_slice(&(used as u32).to_le_bytes());
    Ok(area)
}

fn add_property(area: &mut [u8], used: &mut usize, name: &str, value: &str) -> io::Result<()> {
    if name.len() >= 32 || value.len() >= 92 {
        return Err(io::Error::other("property exceeds ABI bounds"));
    }
    fn get(area: &[u8], at: usize) -> usize {
        u32::from_le_bytes(area[128 + at..132 + at].try_into().unwrap()) as usize
    }
    fn put(area: &mut [u8], at: usize, value: usize) {
        area[128 + at..132 + at].copy_from_slice(&(value as u32).to_le_bytes());
    }
    fn allocate(area: &[u8], used: &mut usize, size: usize) -> io::Result<usize> {
        let at = *used;
        let next = (at + size + 3) & !3;
        if next > area.len() - 128 {
            return Err(io::Error::other("property area full"));
        }
        *used = next;
        Ok(at)
    }
    let mut node = 0;
    for token in name.split('.') {
        if token.is_empty() {
            return Err(io::Error::other("empty property token"));
        }
        let mut link = node + 16;
        node = loop {
            let candidate = get(area, link);
            if candidate == 0 {
                let new = allocate(area, used, 21 + token.len())?;
                area[128 + new] = token.len() as u8;
                area[148 + new..148 + new + token.len()].copy_from_slice(token.as_bytes());
                put(area, link, new);
                break new;
            }
            let length = area[128 + candidate] as usize;
            let order = token.len().cmp(&length).then_with(|| {
                token
                    .as_bytes()
                    .cmp(&area[148 + candidate..148 + candidate + length])
            });
            match order {
                std::cmp::Ordering::Equal => break candidate,
                std::cmp::Ordering::Less => link = candidate + 8,
                std::cmp::Ordering::Greater => link = candidate + 12,
            }
        };
    }
    let property = allocate(area, used, 97 + name.len())?;
    put(area, property, value.len() << 24);
    area[132 + property..132 + property + value.len()].copy_from_slice(value.as_bytes());
    area[224 + property..224 + property + name.len()].copy_from_slice(name.as_bytes());
    put(area, node + 4, property);
    Ok(())
}
