#!/usr/bin/env bash
# Generic VExpress QEMU kernel only. Never package this for the physical MiBox.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${MIBOX_KERNEL_WORK:-$HOME/.cache/mibox-kernel}"
bash "$ROOT/scripts/prepare-mibox-kernel.sh"
ARCHIVE="$ROOT/target/docker-qemu-download/linux-3.10.108.tar.xz"
echo '3849ea8119517f605f9d53c57dd6c539af8d584c2f1d9031f4f56283af3409a5  '"$ARCHIVE" | sha256sum -c -
SOURCE="$WORK/linux-3.10.108"
if [[ ! -d "$SOURCE" ]]; then tar -xJf "$ARCHIVE" -C "$WORK"; fi
OUTPUT="$WORK/build-qemu-upstream310-docker"
LOG="$ROOT/target/docker-qemu-legacy"
mkdir -p "$OUTPUT" "$LOG"
export ARCH=arm CROSS_COMPILE="$WORK/toolchain/bin/arm-linux-androideabi-"
export KBUILD_BUILD_USER=mibox KBUILD_BUILD_HOST=mibox-qemu
export KBUILD_BUILD_TIMESTAMP='2026-11-15 00:00:00 UTC' KBUILD_BUILD_VERSION=1
FLAGS='-Wall -Wmissing-prototypes -Wstrict-prototypes -O2 -fomit-frame-pointer -std=gnu89 -fcommon'
LINKER="${CROSS_COMPILE}ld.bfd"
make -C "$SOURCE" O="$OUTPUT" HOSTCFLAGS="$FLAGS" LD="$LINKER" vexpress_defconfig > "$LOG/configure.log" 2>&1
bash "$SOURCE/scripts/kconfig/merge_config.sh" -m -O "$OUTPUT" "$OUTPUT/.config" \
    "$ROOT/kernel/meson6-containers-v1.config" "$ROOT/kernel/qemu-vexpress-docker.config" >> "$LOG/configure.log" 2>&1
make -C "$SOURCE" O="$OUTPUT" HOSTCFLAGS="$FLAGS" LD="$LINKER" olddefconfig >> "$LOG/configure.log" 2>&1
cp "$OUTPUT/.config" "$LOG/resolved.config"
make -C "$SOURCE" O="$OUTPUT" HOSTCFLAGS="$FLAGS" LD="$LINKER" -j8 zImage > "$LOG/build.log" 2>&1 || {
    tail -n 60 "$LOG/build.log" >&2; exit 1;
}
cp "$OUTPUT/arch/arm/boot/zImage" "$LOG/"
# Invoke the built dtc directly and leave all source files untouched.
"$OUTPUT/scripts/dtc/dtc" -I dts -O dtb -i "$SOURCE/arch/arm/boot/dts" \
    -o "$LOG/vexpress-v2p-ca9.dtb" "$SOURCE/arch/arm/boot/dts/vexpress-v2p-ca9.dts"
sha256sum "$LOG/zImage" "$LOG/vexpress-v2p-ca9.dtb" "$LOG/resolved.config" > "$LOG/SHA256SUMS"
echo 'QEMU-only VExpress kernel built; never a MiBox board candidate'
