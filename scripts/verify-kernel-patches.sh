#!/usr/bin/env bash
# Exact check that a kernel source tree is its pinned HEAD plus every
# kernel/patches/*.patch and nothing else (tracked edits, new files and
# untracked files alike). Applies the patches in name order to a scratch
# index, snapshots the working tree into another scratch index, and compares
# the two tree hashes. Unlike comparing `git diff` with the concatenated
# patches, this does not require the patches to be in global path order.
# Usage: verify-kernel-patches.sh SOURCE PATCH_DIR   (prints the tree hash)
set -euo pipefail
source=$1 patch_dir=$(cd "$2" && pwd)
scratch=$(mktemp -d); trap 'rm -rf "$scratch"' EXIT
export GIT_INDEX_FILE="$scratch/expected"
git -C "$source" read-tree HEAD
for patch_file in "$patch_dir"/*.patch; do
    git -C "$source" apply --cached "$patch_file"
done
expected=$(git -C "$source" write-tree)
export GIT_INDEX_FILE="$scratch/actual"
git -C "$source" read-tree HEAD
git -C "$source" add -A .
actual=$(git -C "$source" write-tree)
if [[ "$expected" != "$actual" ]]; then
    echo "Kernel source differs from HEAD plus the recorded patches ($actual != $expected)" >&2
    git -C "$source" diff --stat "$expected" "$actual" >&2 || true
    exit 1
fi
echo "$actual"
