set -u
echo "== hook"; ls -l /etc/apk/commit_hooks.d; sha256sum /etc/apk/commit_hooks.d/mibox-floor.sh
apk info -e tree && { echo "tree already installed; abort"; exit 1; }
sed 's/^floor_kib=.*/floor_kib=999999999/' /etc/apk/commit_hooks.d/mibox-floor.sh > /etc/apk/commit_hooks.d/zz-high-floor-probe.sh
chmod 755 /etc/apk/commit_hooks.d/zz-high-floor-probe.sh
echo "== /sbin/apk add tree (non-interactive, bypasses PATH guard)"; /sbin/apk add --no-cache tree 2>&1 | tail -4; echo rc=$?
rm -f /etc/apk/commit_hooks.d/zz-high-floor-probe.sh
echo "== tree installed?"; apk info -e tree; echo info_rc=$?
echo "== real hook allows normal add"; /sbin/apk add --no-cache tree >/dev/null 2>&1; echo add_rc=$?; apk info -e tree
/sbin/apk del tree >/dev/null 2>&1; echo del_rc=$?; apk info -e tree; echo after_del_info_rc=$?
ls /etc/apk/commit_hooks.d
