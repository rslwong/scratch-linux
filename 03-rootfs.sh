#!/bin/sh
# Turn the BusyBox tree into a bootable userspace: init config, an rc script,
# and the two device nodes PID 1 needs before devtmpfs is up. Needs sudo only
# for mknod (creating device nodes is root-only).
set -eu
. "$(dirname "$0")/config.sh"

cd "$ROOTFS"
mkdir -p proc sys dev etc/init.d root mnt

# Kernel runs /init as PID 1 from an initramfs. On a persistent disk the kernel
# runs /sbin/init directly. Both funnel through BusyBox init, so one config
# serves both modes.
cat > init <<'EOF'
#!/bin/sh
exec /sbin/init
EOF
chmod +x init

cat > etc/inittab <<'EOF'
::sysinit:/etc/init.d/rcS
ttyS0::respawn:-/bin/sh
tty1::respawn:-/bin/sh
::ctrlaltdel:/sbin/reboot
::shutdown:/bin/umount -a -r
EOF

cat > etc/init.d/rcS <<'EOF'
#!/bin/sh
mount -t proc     none /proc
mount -t sysfs    none /sys
mount -t devtmpfs none /dev 2>/dev/null
mount -o remount,rw / 2>/dev/null   # no-op for initramfs, makes disk root writable
echo
echo "scratch-linux ready  ($(busybox | sed -n 1p))"
echo
EOF
# Audio (AUDIO=1 build): unmute/init the card at boot so it's usable straight
# away. alsactl comes from alsa-utils (04-apps.sh); harmless no-op without it.
if [ "$AUDIO" = 1 ]; then
  cat >> etc/init.d/rcS <<'EOF'
command -v alsactl >/dev/null && alsactl init >/dev/null 2>&1
EOF
fi

# Networking (NET=1 build): bring up wired links and grab a DHCP lease. wlan
# links come up too but won't associate without firmware + wpa_supplicant.
if [ "$NET" = 1 ]; then
  cat >> etc/init.d/rcS <<'EOF'
ifconfig lo 127.0.0.1 up 2>/dev/null
for d in $(ls /sys/class/net 2>/dev/null); do
  [ "$d" = lo ] && continue
  ip link set "$d" up 2>/dev/null
  case "$d" in eth*|en*) udhcpc -i "$d" -b -t 5 2>/dev/null ;; esac
done
EOF
  # udhcpc shells out to this hook to actually apply the lease it receives.
  mkdir -p usr/share/udhcpc
  cat > usr/share/udhcpc/default.script <<'EOF'
#!/bin/sh
case "$1" in
  deconfig) ifconfig "$interface" 0.0.0.0 ;;
  bound|renew)
    ifconfig "$interface" "$ip" netmask "${subnet:-255.255.255.0}"
    [ -n "$router" ] && { ip route del default 2>/dev/null; ip route add default via "$router"; }
    : > /etc/resolv.conf
    for s in $dns; do echo "nameserver $s" >> /etc/resolv.conf; done
    ;;
esac
EOF
  chmod +x usr/share/udhcpc/default.script
fi

chmod +x etc/init.d/rcS

# /dev/console + /dev/null must exist before devtmpfs mounts (initramfs case).
sudo mknod -m 622 dev/console c 5 1 2>/dev/null || true
sudo mknod -m 666 dev/null    c 1 3 2>/dev/null || true

echo "rootfs ready at $ROOTFS"
