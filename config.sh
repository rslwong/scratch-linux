#!/bin/sh
# Shared configuration. Sourced by every other script. Override any value by
# exporting it before you run a step, e.g.:  KERNEL_VER=6.6.52 ./02-kernel.sh
set -eu

# --- versions ----------------------------------------------------------------
BUSYBOX_VER="${BUSYBOX_VER:-1.36.1}"
KERNEL_VER="${KERNEL_VER:-6.6.30}"
KERNEL_MAJOR="${KERNEL_MAJOR:-6}"      # v6.x on kernel.org

# --- layout ------------------------------------------------------------------
# Default off the project dir: on a Lima VM that dir is a slow macOS mount where
# tar fails with "Permission denied". $HOME is the VM's native disk. ponytail: a
# native x86_64 host builds here just as happily.
WORK="${WORK:-$HOME/build}"
SRC="$WORK/src"                        # downloaded + extracted sources
ROOTFS="$WORK/rootfs"                  # the system we are building
OUT="$WORK/out"                        # bzImage + initramfs land here
JOBS="$(nproc 2>/dev/null || echo 2)"

# --- build architecture ------------------------------------------------------
# The target is always x86_64. When the build host is a different arch (e.g. a
# native arm64 VM on an Apple Silicon Mac) we cross-compile, so the build runs
# at full speed instead of under slow x86 emulation. On an x86_64 host this is a
# plain native build. Exporting these lets kbuild and BusyBox pick them up with
# no per-make flags. Override CROSS_COMPILE yourself if your toolchain differs.
ARCH="${ARCH:-x86_64}"
if [ -z "${CROSS_COMPILE:-}" ] && [ "$(uname -m)" != "x86_64" ]; then
  CROSS_COMPILE="x86_64-linux-gnu-"
fi
CROSS_COMPILE="${CROSS_COMPILE:-}"
export ARCH CROSS_COMPILE

# --- optional features -------------------------------------------------------
# Basic build is networkless and silent. Flip these to 1 for the enhanced build;
# they gate kernel drivers (02) and the rootfs init (03), so set them on both:
#   NET=1    TCP/IP stack + ethernet & wifi drivers; init runs DHCP on wired NICs
#   AUDIO=1  ALSA + common sound drivers (HD-audio, USB, QEMU ac97)
# e.g.  NET=1 AUDIO=1 ./02-kernel.sh && NET=1 ./03-rootfs.sh
# Wifi drivers are built in, but associating needs firmware blobs + wpa_supplicant
# (not in BusyBox); audio nodes appear under /dev/snd but BusyBox ships no aplay.
NET="${NET:-0}"
AUDIO="${AUDIO:-0}"

# --- target ------------------------------------------------------------------
# Boot style: "initramfs" (whole system in RAM, read-only) or
#             "persistent" (real ext4 root on the stick, changes survive).
MODE="${MODE:-initramfs}"

# Firmware the target boots with: "bios" (MBR + syslinux/extlinux) or
#                                 "uefi" (GPT + GRUB on an EFI System Partition).
FIRMWARE="${FIRMWARE:-bios}"

# USB block device for last-usb.sh, e.g. /dev/sdb. Empty on purpose so nobody
# wipes a disk by accident — you set it explicitly when you run step 4.
USB_DEV="${USB_DEV:-}"

mkdir -p "$SRC" "$ROOTFS" "$OUT"
