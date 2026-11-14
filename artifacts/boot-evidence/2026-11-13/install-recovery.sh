#!/system/bin/sh
if ! applypatch -c MTD:recovery:6794846:e94825710e912cc47f09dee1be17fb43d1fc564d; then
  log -t recovery "Installing new recovery image"
  applypatch -b /system/etc/recovery-resource.dat MTD:boot:4433609:2dafa19e539ef3a5a674d3f13ff6df9ab483220f MTD:recovery e94825710e912cc47f09dee1be17fb43d1fc564d 6794846 2dafa19e539ef3a5a674d3f13ff6df9ab483220f:/system/recovery-from-boot.p
else
  log -t recovery "Recovery image already installed"
fi
