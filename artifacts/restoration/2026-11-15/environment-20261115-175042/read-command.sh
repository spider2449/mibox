
set -eu
test "$(id -u)" = 0
grep -qx ID=mibox-custom /proc/1/root/etc/os-release
test "$(cat /proc/sys/kernel/random/boot_id)" = b5567c71-9f2e-4d73-9239-0a80e7120ab3
test "$(cat /sys/class/block/env/dev)" = 179:3
test "$(cat /sys/class/block/env/size)" = 8192
test "$(cat /sys/class/block/env/ro)" = 0
test "$(stat -f -c %t /proc/1/root/tmp)" = 858458f6
test ! -e /proc/1/root/tmp/mibox-env-read-20261115-175042
trap 'rm -f /proc/1/root/tmp/mibox-env-read-20261115-175042' EXIT
mknod -m 400 /proc/1/root/tmp/mibox-env-read-20261115-175042 b 179 3
test "$(stat -c %t:%T /proc/1/root/tmp/mibox-env-read-20261115-175042)" = b3:3
test -z "$(awk '$3 == "179:3" {print}' /proc/self/mountinfo)"
echo ENV_SHA256_BEFORE >&2
sha256sum /proc/1/root/tmp/mibox-env-read-20261115-175042 >&2
dd if=/proc/1/root/tmp/mibox-env-read-20261115-175042 bs=65536 count=64
echo ENV_SHA256_AFTER >&2
sha256sum /proc/1/root/tmp/mibox-env-read-20261115-175042 >&2
test "$(cat /proc/sys/kernel/random/boot_id)" = b5567c71-9f2e-4d73-9239-0a80e7120ab3
echo ENV_READ_COMPLETE >&2
