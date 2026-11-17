echo "== identity"; id -u; grep ^ID= /etc/os-release; test -f /etc/mibox-persistent-root && echo IN_ALPINE_TREE
echo "== root of this shell"; readlink /proc/self/root
echo "== host key"; cut -d' ' -f1,2 /etc/dropbear/dropbear_ed25519_host_key.pub
echo "== packages"; apk info -e coreutils dropbear htop python3
echo "== guard"; sha256sum /usr/local/sbin/apk
echo "== free"; df -Pk / | tail -1
echo "== sentinel"; cat /root/slim-physical-sentinel 2>/dev/null || echo none
echo "SLIM_PHYSICAL_$(cat /proc/sys/kernel/random/boot_id)" > /root/slim-physical-sentinel; sync; cat /root/slim-physical-sentinel
echo "== ram supervisor"; cat /proc/1/root/run/mibox-alpine-supervisor.pid
