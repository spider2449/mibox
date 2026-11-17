set -u
apk info -e tree && { echo "tree already installed; abort probe"; exit 1; }
mkdir -p /etc/apk/commit_hooks.d
printf '#!/bin/sh\necho "probe hook called: $1" >&2\n[ "$1" = pre-commit ] && exit 1\nexit 0\n' > /etc/apk/commit_hooks.d/zz-probe.sh
chmod 755 /etc/apk/commit_hooks.d/zz-probe.sh
echo "== add with failing pre-commit hook"; /sbin/apk add --no-cache tree 2>&1; echo rc=$?
echo "== installed?"; apk info -e tree; echo info_rc=$?
rm -f /etc/apk/commit_hooks.d/zz-probe.sh
rmdir /etc/apk/commit_hooks.d 2>/dev/null
ls -la /etc/apk/commit_hooks.d 2>&1 | head -2
