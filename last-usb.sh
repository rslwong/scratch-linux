#!/bin/sh
# Write the bootable USB. Two axes:
#   FIRMWARE=bios   -> MBR + syslinux (initramfs) / extlinux (persistent)
#   FIRMWARE=uefi   -> GPT + GRUB on an EFI System Partition
#   MODE=initramfs  -> system unpacked into RAM, root-only
#   MODE=persistent -> real ext4 root, changes survive reboot
# Destructive: it repartitions USB_DEV. Run as a user who can sudo.
set -eu
. "$(dirname "$0")/config.sh"

[ -n "$USB_DEV" ] || { echo "Set USB_DEV, e.g.  USB_DEV=/dev/sdb FIRMWARE=$FIRMWARE MODE=$MODE $0"; exit 1; }
[ -b "$USB_DEV" ] || { echo "$USB_DEV is not a block device"; exit 1; }

echo "About to ERASE this device:"
lsblk -o NAME,SIZE,MODEL,MOUNTPOINT "$USB_DEV" || true
printf 'Type ERASE to continue: '; read ans; [ "$ans" = ERASE ] || { echo aborted; exit 1; }

# initramfs image — cheap to always build, needed by both initramfs variants.
( cd "$ROOTFS" && find . | cpio -o -H newc 2>/dev/null | gzip -9 ) > "$OUT/initramfs.cpio.gz"

# /dev/sdb1 vs /dev/mmcblk0p1
partn() { p="${USB_DEV}$1"; [ -b "$p" ] || p="${USB_DEV}p$1"; printf %s "$p"; }
mnt="$(mktemp -d)"

# write file $2.. (newline-joined) to path $1 via sudo
writecfg() { f="$1"; shift; printf '%s\n' "$@" | sudo tee "$f" >/dev/null; }

sudo wipefs -a "$USB_DEV"

case "$FIRMWARE" in
bios)
  mbr="$(ls /usr/lib/syslinux/mbr/mbr.bin /usr/lib/syslinux/mbr.bin \
            /usr/share/syslinux/mbr.bin 2>/dev/null | head -1)"
  [ -n "$mbr" ] || { echo "mbr.bin not found — install the syslinux package"; exit 1; }
  printf 'label: dos\n,,L,*\n' | sudo sfdisk "$USB_DEV"
  sudo partprobe "$USB_DEV" 2>/dev/null || true
  p1="$(partn 1)"

  if [ "$MODE" = initramfs ]; then
    sudo mkfs.vfat -F32 "$p1"
    sudo mount "$p1" "$mnt"
    sudo cp "$OUT/bzImage" "$OUT/initramfs.cpio.gz" "$mnt/"
    sudo mkdir -p "$mnt/syslinux"
    writecfg "$mnt/syslinux/syslinux.cfg" \
      'DEFAULT linux' 'PROMPT 0' 'TIMEOUT 30' \
      'LABEL linux' '  LINUX /bzImage' '  INITRD /initramfs.cpio.gz' \
      '  APPEND console=tty1 console=ttyS0'
    sudo umount "$mnt"
    sudo syslinux --install --directory /syslinux "$p1"
  else
    sudo mkfs.ext4 -F "$p1"
    sudo mount "$p1" "$mnt"
    sudo cp -a "$ROOTFS"/. "$mnt"/
    sudo mkdir -p "$mnt/boot/syslinux"
    sudo cp "$OUT/bzImage" "$mnt/boot/"
    puuid="$(sudo blkid -s PARTUUID -o value "$p1")"
    writecfg "$mnt/boot/syslinux/syslinux.cfg" \
      'DEFAULT linux' 'PROMPT 0' 'TIMEOUT 30' \
      'LABEL linux' '  LINUX /boot/bzImage' \
      "  APPEND root=PARTUUID=$puuid rootwait rw console=tty1 console=ttyS0"
    sudo extlinux --install "$mnt/boot/syslinux"
    sudo umount "$mnt"
  fi
  sudo dd bs=440 count=1 conv=notrunc if="$mbr" of="$USB_DEV"   # BIOS -> syslinux
  ;;

uefi)
  command -v grub-install >/dev/null \
    || { echo "grub-install missing — install grub-efi-amd64-bin grub-common"; exit 1; }

  if [ "$MODE" = initramfs ]; then
    # One EFI System Partition holds everything.
    printf 'label: gpt\n,,U,*\n' | sudo sfdisk "$USB_DEV"
    sudo partprobe "$USB_DEV" 2>/dev/null || true
    esp="$(partn 1)"
    sudo mkfs.vfat -F32 "$esp"
    sudo mount "$esp" "$mnt"
    sudo mkdir -p "$mnt/boot"
    sudo cp "$OUT/bzImage" "$OUT/initramfs.cpio.gz" "$mnt/boot/"
    cmdline='console=tty1 console=ttyS0'
    initrd_line='  initrd /boot/initramfs.cpio.gz'
  else
    # ESP for kernel+GRUB, separate ext4 partition for the real root.
    printf 'label: gpt\n,512M,U\n,,L\n' | sudo sfdisk "$USB_DEV"
    sudo partprobe "$USB_DEV" 2>/dev/null || true
    esp="$(partn 1)"; root="$(partn 2)"
    sudo mkfs.vfat -F32 "$esp"
    sudo mkfs.ext4 -F "$root"
    puuid="$(sudo blkid -s PARTUUID -o value "$root")"
    sudo mount "$root" "$mnt"; sudo cp -a "$ROOTFS"/. "$mnt"/; sudo umount "$mnt"
    sudo mount "$esp" "$mnt"
    sudo mkdir -p "$mnt/boot"
    sudo cp "$OUT/bzImage" "$mnt/boot/"
    cmdline="root=PARTUUID=$puuid rootwait rw console=tty1 console=ttyS0"
    initrd_line=''
  fi

  # --removable installs to /EFI/BOOT/BOOTX64.EFI, which firmware auto-boots
  # from a USB stick without needing an NVRAM boot entry.
  sudo grub-install --target=x86_64-efi --removable --no-nvram \
    --efi-directory="$mnt" --boot-directory="$mnt/boot" "$USB_DEV"
  sudo mkdir -p "$mnt/boot/grub"
  writecfg "$mnt/boot/grub/grub.cfg" \
    'set timeout=3' 'set default=0' \
    'menuentry "scratch-linux" {' \
    "  linux /boot/bzImage $cmdline" \
    ${initrd_line:+"$initrd_line"} \
    '}'
  sudo umount "$mnt"
  ;;

*) echo "FIRMWARE must be bios or uefi"; exit 1 ;;
esac

rmdir "$mnt"; sudo sync
echo "Done. $USB_DEV is bootable ($FIRMWARE / $MODE)."
