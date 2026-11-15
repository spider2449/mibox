#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SYSROOT="$ROOT/target/hardware-cross/sysroot/usr/arm-linux-gnueabihf"
[[ -f "$SYSROOT/include/stdio.h" ]] || {
    echo 'Prepare the isolated ARM sysroot using scripts/build-hardware-helper.py first' >&2; exit 2;
}
arm-linux-gnueabihf-gcc --sysroot="$SYSROOT" -isystem "$SYSROOT/include" \
    -L"$SYSROOT/lib" -B"$SYSROOT/lib/" -static -Os -Wall -Wextra -Werror \
    -o "$ROOT/target/kernel-meson6/mibox-kernel-selftest" "$ROOT/src/hardware/mibox-kernel-selftest.c"
arm-linux-gnueabihf-readelf -h -l "$ROOT/target/kernel-meson6/mibox-kernel-selftest" \
    > "$ROOT/target/kernel-meson6/selftest-elf.txt"
if grep -q 'INTERP\|DYNAMIC' "$ROOT/target/kernel-meson6/selftest-elf.txt"; then
    echo 'Selftest helper must be static' >&2; exit 2;
fi
sha256sum "$ROOT/target/kernel-meson6/mibox-kernel-selftest"
