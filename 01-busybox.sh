#!/bin/sh
# Build BusyBox as a single static binary and install its applet symlinks into
# the rootfs. Static = the target needs no C library, which keeps us honest.
set -eu
. "$(dirname "$0")/config.sh"

cd "$SRC"
tarball="busybox-$BUSYBOX_VER.tar.bz2"
[ -f "$tarball" ] || wget "https://busybox.net/downloads/$tarball"
[ -d "busybox-$BUSYBOX_VER" ] || tar xf "$tarball"
cd "busybox-$BUSYBOX_VER"

make defconfig
# Force a fully static build (.config ships this as "# CONFIG_STATIC is not set").
sed -i 's/.*CONFIG_STATIC[ =].*/CONFIG_STATIC=y/' .config
# Disable the tc applet — it fails to compile against modern kernel headers.
sed -i 's/^CONFIG_TC=y/# CONFIG_TC is not set/' .config
yes "" | make oldconfig >/dev/null

make -j"$JOBS"
make CONFIG_PREFIX="$ROOTFS" install   # creates bin/ sbin/ usr/ + applet symlinks

echo "BusyBox $BUSYBOX_VER installed into $ROOTFS"
