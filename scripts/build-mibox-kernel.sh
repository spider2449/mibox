#!/usr/bin/env bash
# Offline development kernels only. Does not package or deploy boot images.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${MIBOX_KERNEL_WORK:-$HOME/.cache/mibox-kernel}"
PROFILE="${1:-containers-v1}"
case "$PROFILE" in baseline|containers-v1) ;; *) echo 'Use baseline or containers-v1' >&2; exit 2 ;; esac
bash "$ROOT/scripts/prepare-mibox-kernel.sh"
SOURCE="$WORK/vendor-source"
export MIBOX_KERNEL_SOURCE_DIFF_SHA256="$(git -C "$SOURCE" diff --no-ext-diff --binary --abbrev=8 | sha256sum | cut -d ' ' -f1)"
OUTPUT="$WORK/build-$PROFILE"
LOG="$ROOT/target/kernel-meson6/$PROFILE"
mkdir -p "$OUTPUT" "$LOG"
export ARCH=arm CROSS_COMPILE="$WORK/toolchain/bin/arm-linux-androideabi-"
export KBUILD_BUILD_USER=mibox KBUILD_BUILD_HOST=mibox-wsl
export KBUILD_BUILD_TIMESTAMP='2026-11-15 00:00:00 UTC'
export KBUILD_BUILD_VERSION=1
# Old dtc's tentative yylloc definitions require pre-GCC-10 common semantics.
MAKE_HOST_FLAGS='-Wall -Wmissing-prototypes -Wstrict-prototypes -O2 -fomit-frame-pointer -std=gnu89 -fcommon'
MAKE_LINKER="${CROSS_COMPILE}ld.bfd"
STOCK="$ROOT/artifacts/platform/2026-11-14/stock-kernel.config"
echo 'bd2a94b6aa84afda30661c3a4b41f9759fcc6734ee32daf8335882ba6b43c918  '"$STOCK" | sha256sum -c -
CONFIG_KEY="$(sha256sum "$STOCK" "$ROOT/kernel/meson6-bsp-build.config" \
    "$ROOT/kernel/meson6-containers-v1.config" "$ROOT/kernel/patches/"*.patch | sha256sum)"
if [[ -f "$OUTPUT/config-input.sha256" && "$(cat "$OUTPUT/config-input.sha256")" == "$CONFIG_KEY" ]] \
    && sha256sum -c "$OUTPUT/config-output.sha256" >/dev/null 2>&1; then
    echo 'Reusing the verified resolved configuration'
else
    cp "$STOCK" "$OUTPUT/.config"
    make -C "$SOURCE" O="$OUTPUT" HOSTCFLAGS="$MAKE_HOST_FLAGS" LD="$MAKE_LINKER" olddefconfig > "$LOG/configure.log" 2>&1
    bash "$SOURCE/scripts/kconfig/merge_config.sh" -m -O "$OUTPUT" \
        "$OUTPUT/.config" "$ROOT/kernel/meson6-bsp-build.config" >> "$LOG/configure.log" 2>&1
    make -C "$SOURCE" O="$OUTPUT" HOSTCFLAGS="$MAKE_HOST_FLAGS" LD="$MAKE_LINKER" olddefconfig >> "$LOG/configure.log" 2>&1
    if [[ "$PROFILE" == containers-v1 ]]; then
        bash "$SOURCE/scripts/kconfig/merge_config.sh" -m -O "$OUTPUT" \
            "$OUTPUT/.config" "$ROOT/kernel/meson6-containers-v1.config" >> "$LOG/configure.log" 2>&1
        make -C "$SOURCE" O="$OUTPUT" HOSTCFLAGS="$MAKE_HOST_FLAGS" LD="$MAKE_LINKER" olddefconfig >> "$LOG/configure.log" 2>&1
    fi
    printf '%s\n' "$CONFIG_KEY" > "$OUTPUT/config-input.sha256"
    sha256sum "$OUTPUT/.config" > "$OUTPUT/config-output.sha256"
fi
cp "$OUTPUT/.config" "$LOG/resolved.config"
python3 "$ROOT/scripts/record-mibox-kernel.py" --work "$WORK" --profile "$PROFILE" --configure-only
echo "Building $PROFILE; log: $LOG/build.log"
printf '%s\n' "$MIBOX_KERNEL_SOURCE_DIFF_SHA256" > "$OUTPUT/build-source.sha256"
sha256sum "$OUTPUT/.config" > "$OUTPUT/build-config.sha256"
make -C "$SOURCE" O="$OUTPUT" HOSTCFLAGS="$MAKE_HOST_FLAGS" LD="$MAKE_LINKER" -j"${MIBOX_KERNEL_JOBS:-8}" zImage > "$LOG/build.log" 2>&1 || {
    tail -n 65 "$LOG/build.log" >&2; exit 1;
}
python3 "$ROOT/scripts/record-mibox-kernel.py" --work "$WORK" --profile "$PROFILE"
