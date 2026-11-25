#!/usr/bin/env bash
# Run in Linux/WSL. Immutable source/compiler pins; no device access.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${MIBOX_KERNEL_WORK:-$HOME/.cache/mibox-kernel}"
SOURCE_SHA=8b1bb2b31a8e94b773a4b8ab907a0473a0951192
TOOLCHAIN_SHA=111258a10e017f067b27e6cfcea7619d753f3309
mkdir -p "$WORK"
case "$(stat -f -c %T "$WORK")" in
    9p|drvfs|ntfs|fuseblk) echo 'Source/build must use a case-sensitive Linux filesystem' >&2; exit 2 ;;
esac
fetch_pin() {
    local destination="$1" url="$2" sha="$3" patch_dir="${4:-}"
    if [[ ! -e "$destination" ]]; then
        git init -q "$destination"
        git -C "$destination" remote add origin "$url"
        git -C "$destination" fetch --depth 1 origin "$sha"
        git -C "$destination" checkout --detach FETCH_HEAD
    fi
    [[ "$(git -C "$destination" rev-parse HEAD)" == "$sha" ]] || {
        echo "Unexpected source revision at $destination; preserving it" >&2; exit 2;
    }
    if [[ -n "$patch_dir" ]]; then
        for patch_file in "$patch_dir"/*.patch; do
            if ! git -C "$destination" apply --reverse --check "$patch_file" 2>/dev/null; then
                git -C "$destination" apply --check "$patch_file"
                # --intent-to-add: new files appear in `git diff`, so the
                # recorded source diff hash covers them.
                git -C "$destination" apply --intent-to-add "$patch_file"
            fi
        done
        bash "$ROOT/scripts/verify-kernel-patches.sh" "$destination" "$patch_dir" > /dev/null || {
            echo "Unrecorded source changes at $destination; preserving it" >&2; exit 2;
        }
    else
        [[ -z "$(git -C "$destination" status --porcelain)" ]] || {
            echo "Modified source at $destination; preserving it" >&2; exit 2;
        }
    fi
}
fetch_pin "$WORK/vendor-source" https://github.com/codesnake/linux-amlogic.git "$SOURCE_SHA" \
    "$ROOT/kernel/patches"
fetch_pin "$WORK/toolchain" https://github.com/LineageOS/android_prebuilts_gcc_linux-x86_arm_arm-linux-androideabi-4.9.git "$TOOLCHAIN_SHA"
"$WORK/toolchain/bin/arm-linux-androideabi-gcc" --version | head -n 1
echo "Prepared $WORK (source $SOURCE_SHA, compiler $TOOLCHAIN_SHA)"
