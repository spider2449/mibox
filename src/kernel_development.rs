//! Exact development release/marker pair; enabled only in the test userspace.
pub const MARKER: &[u8] =
    b"MIBOX_KERNEL_DEV_V1 8b1bb2b31a8e94b773a4b8ab907a0473a0951192 3.10.99-mibox-container-dev+\n";

pub fn accepts(release: &str, marker: &[u8]) -> bool {
    cfg!(feature = "container-kernel-test") && release == "3.10.99" && marker == MARKER
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exact_pair_requires_the_build_feature() {
        assert_eq!(
            accepts("3.10.99", MARKER),
            cfg!(feature = "container-kernel-test")
        );
    }

    #[test]
    fn other_releases_or_marker_contents_are_rejected() {
        for release in [
            "3.10.33",
            "3.10.990",
            "3.10.99-mibox-container-dev",
            "3.10.99-mibox-container-dev+",
            "6.12.0",
        ] {
            assert!(!accepts(release, MARKER));
        }
        for marker in [b"".as_slice(), &MARKER[..MARKER.len() - 1], b"enabled\n"] {
            assert!(!accepts("3.10.99", marker));
        }
    }
}
