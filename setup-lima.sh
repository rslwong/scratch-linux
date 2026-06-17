#!/bin/sh
# One-shot: on macOS, create a NATIVE Linux VM (same arch as your Mac) with the
# build deps installed and this folder mounted writable, then run 01..04 inside.
# On Apple Silicon the VM is arm64 (fast, hardware-accelerated) and the build
# cross-compiles to x86_64 — config.sh does that automatically.
#
# Deps are installed AFTER the VM is up (not in Lima's `provision` block) so the
# install can't trip Lima's startup timeout.
set -eu

VM="${VM:-scratch}"
HERE="$(cd "$(dirname "$0")" && pwd)"

# build tools (native) + the x86_64 cross-compiler + static cross libc +
# qemu/ovmf for testing the x86 image + fs tools for making disk images.
PKGS="build-essential bc bison flex libelf-dev libssl-dev \
wget xz-utils cpio \
gcc-x86-64-linux-gnu libc6-dev-amd64-cross \
qemu-system-x86 ovmf \
dosfstools e2fsprogs"

command -v limactl >/dev/null || { echo "Install Lima first:  brew install lima"; exit 1; }

if limactl list -q 2>/dev/null | grep -qx "$VM"; then
  echo "VM '$VM' already exists."
  echo "If it's the old emulated x86_64 one, delete it first:  limactl delete --force $VM"
  limactl list "$VM" --format '{{.Status}}' 2>/dev/null | grep -qi running \
    || limactl start "$VM"
else
  tmp="$(mktemp).yaml"
  # Both arches listed; Lima picks the one matching your Mac (no top-level
  # 'arch', so the VM defaults to the host arch and runs natively).
  cat > "$tmp" <<EOF
images:
  - location: "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-arm64.img"
    arch: "aarch64"
  - location: "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"
    arch: "x86_64"
cpus: 4
memory: "6GiB"
disk: "20GiB"
mounts:
  - location: "$HERE"
    writable: true
EOF
  echo "Creating native VM '$VM'..."
  limactl start --name="$VM" --tty=false "$tmp"
  rm -f "$tmp"
fi

echo "Installing build dependencies inside the VM..."
limactl shell "$VM" -- sudo sh -c \
  "export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get install -y $PKGS"

cat <<EOF

VM ready. Get a shell in it:
  limactl shell $VM

Your project is mounted at:  $HERE

Build (cross-compiles to x86_64 automatically) and test in QEMU — no USB needed:
  cd $HERE
  export WORK=\$HOME/build   # build on the VM's native disk; the macOS mount is
                             # slow and makes tar fail with "Permission denied"
  ./01-busybox.sh && ./02-kernel.sh && ./03-rootfs.sh
  ( cd work/rootfs && find . | cpio -o -H newc | gzip -9 ) > work/out/initramfs.cpio.gz
  qemu-system-x86_64 -m 256 -nographic \\
    -kernel work/out/bzImage -initrd work/out/initramfs.cpio.gz -append console=ttyS0
  #   Ctrl-a x  quits qemu

NOTE: writing a physical stick (04-usb.sh) uses x86-only bootloaders
(syslinux/extlinux/grub-efi-amd64) that aren't available on arm64. Build + test
here, then run 04-usb.sh on an x86_64 Linux machine to write the actual USB.
EOF
