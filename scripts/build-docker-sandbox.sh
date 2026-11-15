#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SYSROOT="$ROOT/target/hardware-cross/sysroot/usr/arm-linux-gnueabihf"
mkdir -p "$ROOT/target/mibox-docker-experiment"
for variant in board qemu qemu-legacy; do
    args=()
    suffix=''
    if [[ "$variant" == qemu ]]; then args=(-DMIBOX_DOCKER_QEMU_TEST); suffix=-qemu; fi
    if [[ "$variant" == qemu-legacy ]]; then args=(-DMIBOX_DOCKER_QEMU_LEGACY_TEST); suffix=-qemu-legacy; fi
arm-linux-gnueabihf-gcc --sysroot="$SYSROOT" -isystem "$SYSROOT/include" \
    -L"$SYSROOT/lib" -B"$SYSROOT/lib/" -static -Os -Wall -Wextra -Werror \
    "${args[@]}" -o "$ROOT/target/mibox-docker-experiment/mibox-docker-sandbox$suffix" \
    "$ROOT/src/hardware/mibox-docker-sandbox.c"
done
arm-linux-gnueabihf-readelf -h -l "$ROOT/target/mibox-docker-experiment/mibox-docker-sandbox"
