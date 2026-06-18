#!/bin/sh
# Build a minimal x86_64 kernel. Everything we depend on is compiled IN, not as
# modules — a from-scratch system has no module loader set up to pull them in.
set -eu
. "$(dirname "$0")/config.sh"

cd "$SRC"
tarball="linux-$KERNEL_VER.tar.xz"
[ -f "$tarball" ] || wget "https://cdn.kernel.org/pub/linux/kernel/v${KERNEL_MAJOR}.x/$tarball"
[ -d "linux-$KERNEL_VER" ] || tar xf "$tarball"
cd "linux-$KERNEL_VER"

make x86_64_defconfig

# defconfig already covers most of these; we assert them so the build is not at
# the mercy of a defconfig change between kernel versions.
scripts/config \
  --enable DEVTMPFS --enable DEVTMPFS_MOUNT \
  --enable BLK_DEV_INITRD \
  --enable EXT4_FS \
  --enable VFAT_FS --enable NLS_CODEPAGE_437 --enable NLS_ISO8859_1 \
  --enable SCSI --enable BLK_DEV_SD \
  --enable USB --enable USB_XHCI_HCD --enable USB_EHCI_HCD \
  --enable USB_STORAGE \
  --enable USB_HID --enable HID_GENERIC

# Optional features (config.sh toggles). Built IN, like everything else — this
# system has no module loader. Drivers cover QEMU and common real hardware.
if [ "$NET" = 1 ]; then
  scripts/config \
    --enable NET --enable INET --enable PACKET --enable UNIX \
    --enable NETDEVICES --enable ETHERNET \
    --enable NET_VENDOR_INTEL  --enable E1000 --enable E1000E --enable IGB \
    --enable NET_VENDOR_REALTEK --enable R8169 \
    --enable VIRTIO_NET \
    --enable WLAN --enable CFG80211 --enable CFG80211_WEXT --enable MAC80211 \
    --enable WLAN_VENDOR_INTEL --enable IWLWIFI --enable IWLMVM \
    --enable WLAN_VENDOR_ATH --enable ATH9K
fi
if [ "$AUDIO" = 1 ]; then
  scripts/config \
    --enable SOUND --enable SND --enable SND_PCM \
    --enable SND_HDA_INTEL --enable SND_HDA_CODEC_REALTEK --enable SND_HDA_CODEC_HDMI \
    --enable SND_USB_AUDIO \
    --enable SND_INTEL8X0      # QEMU's default ac97
fi
make olddefconfig

make -j"$JOBS" bzImage
cp arch/x86/boot/bzImage "$OUT/bzImage"
echo "kernel -> $OUT/bzImage"
