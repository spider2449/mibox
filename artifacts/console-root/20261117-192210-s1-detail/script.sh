set -eu
echo '== mounts of 179:11'; awk '$3 == "179:11"' /proc/self/mountinfo | wc -l
mkdir -p /mnt/s1-data-ro
mount -t ext4 -o ro,noload,nosuid,nodev,noexec /dev/mibox-data /mnt/s1-data-ro
trap 'umount /mnt/s1-data-ro; echo UNMOUNTED' EXIT
echo '== local/tmp'; ls -la /mnt/s1-data-ro/local/tmp | head -30
echo '== alpine tmp'; ls -la /mnt/s1-data-ro/mibox-console/rootfs/tmp | head -20
echo '== log'; du -sk /mnt/s1-data-ro/log/* 2>/dev/null | sort -rn | head
echo '== media/0 top'; du -sk /mnt/s1-data-ro/media/0/* 2>/dev/null | sort -rn | head
echo '== ssh'; ls -la /mnt/s1-data-ro/ssh
