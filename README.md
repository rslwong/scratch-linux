# scratch-linux

A from-scratch bootable Linux USB: a custom kernel + a static BusyBox userspace,
AI generated scripts
no distribution involved. Built for learning, but it really boots and gives you
a working shell with the usual utilities.

Two independent choices, set as env vars:

`MODE` — where root lives:

| MODE | Root filesystem | Survives reboot? | Use it to learn |
|------|-----------------|------------------|-----------------|
| `initramfs` (default) | unpacked into RAM by the kernel | no (RAM is wiped) | how the kernel hands off to `/init` |
| `persistent` | real ext4 partition on the stick | yes | how `root=` and a real disk root work |

`FIRMWARE` — how the machine boots:

| FIRMWARE | Disk layout | Bootloader | Use it to learn |
|----------|-------------|------------|-----------------|
| `bios` (default) | MBR | syslinux / extlinux | the legacy MBR boot chain |
| `uefi` | GPT + EFI System Partition | GRUB (`/EFI/BOOT/BOOTX64.EFI`) | how modern UEFI firmware finds a loader |

All four combinations work, e.g. `FIRMWARE=uefi MODE=persistent`.

## What gets built

1. **BusyBox** — one static binary providing `sh`, `mount`, `ls`, `init`, ~300 applets.
2. **Linux kernel** — minimal `x86_64` `bzImage`, USB-storage/ext4/vfat compiled in.
3. **rootfs** — `init`, `/etc/inittab`, an rc script, two device nodes.
4. **USB** — partitioned, bootloader installed, images copied.

```
config.sh        shared settings (versions, paths, MODE, FIRMWARE, USB_DEV)
setup-lima.sh    macOS only: spin up a Linux VM with deps + this folder mounted
01-busybox.sh    download + build static BusyBox  -> work/rootfs
02-kernel.sh     download + build kernel          -> work/out/bzImage
03-rootfs.sh     init + inittab + device nodes    -> work/rootfs
04-apps.sh       optional apps (AUDIO/NET=1)       -> work/rootfs
last-usb.sh      partition + bootloader + copy     -> your USB stick
```

## Optional features

The basic build is networkless and silent. Two toggles (set on every step that
uses them) add more:

| Toggle | Kernel (02) | Init (03) | Apps (04) |
|--------|-------------|-----------|-----------|
| `NET=1`   | TCP/IP + ethernet & wifi drivers | DHCP on wired NICs at boot | `wpa_supplicant` + wifi firmware |
| `AUDIO=1` | ALSA + common sound drivers | `alsactl init` (unmute) at boot | `aplay` / `amixer` / `alsactl` (alsa-utils) |

```sh
NET=1 AUDIO=1 ./02-kernel.sh
NET=1 AUDIO=1 ./03-rootfs.sh
NET=1 AUDIO=1 ./04-apps.sh        # static-cross-builds the userspace tools + firmware
```

Wired ethernet is fully automatic (BusyBox `udhcpc`). Sound: drivers auto-probe
and `04-apps.sh` installs the ALSA tools — `aplay -l` lists cards, `aplay
file.wav` plays.

Wifi firmware is bundled by `04-apps.sh`. By default it fetches **iwlwifi**
(Intel — the common laptop/mini-PC card; ath9k PCIe needs none) via a sparse
`linux-firmware` checkout, so only the listed blobs download, not the ~2 GB
tree. Add families with `FW_LIST` (e.g. `FW_LIST='/iwlwifi-* /rtw88/*'`), or
point `FW_DIR` at a local firmware tree to skip the download. Then on the target:

```sh
wpa_passphrase SSID pass >> /etc/wpa_supplicant.conf
wpa_supplicant -B -i wlan0 -c /etc/wpa_supplicant.conf && udhcpc -i wlan0
```

## Requirements

Runs on **Linux** (Debian/Ubuntu package names shown):

```
sudo apt install build-essential bc bison flex libelf-dev libssl-dev \
                 wget xz-utils cpio git pkg-config \
                 syslinux extlinux dosfstools e2fsprogs
```

For UEFI add `grub-efi-amd64-bin grub-common`; for QEMU testing add
`qemu-system-x86 ovmf`. `gcc`, `make`, `wget`, `cpio`, `sudo`, `lsblk`,
`sfdisk`, `blkid` are assumed present.

**Building on a non-x86_64 host (e.g. arm64):** add the cross-compiler
`gcc-x86-64-linux-gnu libc6-dev-amd64-cross`. `config.sh` detects the host arch
and cross-compiles to x86_64 automatically — no flags to pass. Note that
`syslinux`, `extlinux`, and `grub-efi-amd64-bin` are **x86-only packages**, so
steps 1–3 + QEMU testing work on arm64, but step 4 (writing a real stick) must
run on an x86_64 Linux machine.

### On macOS

You can't build a Linux kernel or run `mkfs` on macOS directly, so run the build
in a Linux VM. The one-shot script does the whole setup:

```sh
brew install lima      # if you don't have it
./setup-lima.sh        # native VM (arm64 on Apple Silicon) + deps + this folder mounted
limactl shell scratch  # drop into the VM; the project is at the same path
```

The VM is your Mac's native arch, so it runs hardware-accelerated and the build
cross-compiles to x86_64 in **minutes**. Inside it, run steps 1–3 then test the
result in QEMU — no physical USB needed (see below).

> Build on the VM's own disk, not the mounted macOS folder:
> `export WORK=$HOME/build` before running the steps. The reverse-sshfs mount is
> slow and makes `tar` fail extracting the kernel with "Permission denied". The
> scripts stay on the mount; only `$WORK` (build output) needs to be native.

> **Why not an emulated x86_64 VM?** Tried it — emulating x86 on Apple Silicon
> is so slow that even BusyBox's pre-build step ran for 10+ minutes; a kernel
> build is hopeless. Native arm64 + cross-compile is the fast, reliable path.
>
> **Writing the real USB stick:** step 4 needs the x86-only bootloader tools,
> which don't exist on arm64. Build + test on your Mac, then run `last-usb.sh` on
> an x86_64 Linux box (a cheap mini-PC, an old laptop, or a cloud x86 instance
> with the stick attached) to flash the actual drive.

## Steps

```sh
cd scratch-linux

./01-busybox.sh          # a few minutes
./02-kernel.sh           # the long one (downloads ~140 MB, compiles)
./03-rootfs.sh           # instant; prompts sudo for mknod
# ./04-apps.sh           # only if AUDIO=1 / NET=1 — see "Optional features" above

# --- pick a firmware + mode combination ---

USB_DEV=/dev/sdX FIRMWARE=bios MODE=initramfs  ./last-usb.sh   # legacy, RAM root
USB_DEV=/dev/sdX FIRMWARE=bios MODE=persistent ./last-usb.sh   # legacy, disk root
USB_DEV=/dev/sdX FIRMWARE=uefi MODE=initramfs  ./last-usb.sh   # UEFI,   RAM root
USB_DEV=/dev/sdX FIRMWARE=uefi MODE=persistent ./last-usb.sh   # UEFI,   disk root
```

Defaults are `FIRMWARE=bios MODE=initramfs`, so a bare `USB_DEV=/dev/sdX ./last-usb.sh`
gives a legacy-BIOS RAM stick. For UEFI, also disable Secure Boot on the target.

Find `/dev/sdX` with `lsblk` **before** plugging the stick and again after — the
new device is yours. `last-usb.sh` erases it and makes you type `ERASE` to confirm.

## Test in QEMU (no USB needed)

Fastest feedback loop — boot the kernel + initramfs straight from `work/out`:

```sh
qemu-system-x86_64 -m 256 -nographic \
  -kernel work/out/bzImage \
  -initrd work/out/initramfs.cpio.gz \
  -append "console=ttyS0"
```

(`initramfs.cpio.gz` is produced by `last-usb.sh`; to make it without touching a
USB, run: `( cd work/rootfs && find . | cpio -o -H newc | gzip -9 ) > work/out/initramfs.cpio.gz`.)

You should land at a `#` prompt. `Ctrl-a x` quits QEMU.

To test a whole **stick** (any firmware/mode) in QEMU, point a raw drive at it:

```sh
qemu-system-x86_64 -m 256 -nographic -drive format=raw,file=/dev/sdX            # BIOS
qemu-system-x86_64 -m 256 -nographic -bios /usr/share/ovmf/OVMF.fd \
  -drive format=raw,file=/dev/sdX                                               # UEFI
```

(The `ovmf` package provides `OVMF.fd`, the open-source UEFI firmware QEMU needs.)

## How it boots

The userspace is identical across all four combinations — `init → /sbin/init →
/etc/inittab → rcS` (mounts `/proc` `/sys` `/dev`, then respawns a shell). Only
the path the firmware takes to the kernel differs:

- **BIOS + initramfs:** firmware → MBR → `syslinux` → `bzImage` + `initramfs.cpio.gz`.
  Kernel unpacks the cpio into a RAM root and runs `/init` (PID 1).
- **BIOS + persistent:** firmware → MBR → `extlinux` → `bzImage` with
  `root=PARTUUID=… rw`; kernel mounts the ext4 partition and runs `/sbin/init`.
- **UEFI + initramfs:** firmware reads the GPT, runs `/EFI/BOOT/BOOTX64.EFI`
  (GRUB) from the ESP, which loads `bzImage` + initramfs. RAM root, as above.
- **UEFI + persistent:** same GRUB hand-off, but it boots with `root=PARTUUID=…`
  pointing at the second (ext4) partition; the ESP only carries kernel + GRUB.

## Customizing

- Add tools: BusyBox `menuconfig` (edit `01-busybox.sh` to run `make menuconfig`).
- Smaller/faster kernel: `make menuconfig` in `work/src/linux-*` after step 2,
  then `make bzImage` and re-copy — keep USB storage, ext4, vfat, devtmpfs **in**.
- Want a login prompt instead of a bare shell: swap the `respawn` lines in
  `03-rootfs.sh` for `getty`.

## Troubleshooting

- **"mbr.bin not found"** — install `syslinux` (or `syslinux-common`).
- **"grub-install missing"** — install `grub-efi-amd64-bin grub-common`.
- **UEFI stick not in the boot menu** — disable Secure Boot; it boots the
  unsigned `/EFI/BOOT/BOOTX64.EFI` fallback that `--removable` installs.
- **Hangs at "VFS: Cannot open root device" (persistent)** — USB enumerated too
  late; `rootwait` is already set. Confirm `BLK_DEV_SD` + `USB_STORAGE` are
  built in (not modules) in your kernel `.config`.
- **No output on screen but works in QEMU serial** — the target may not use
  `ttyS0`; the configs append both `tty1` and `ttyS0`, so a monitor should work.
- **`init: can't open /dev/console`** — step 3's `mknod` didn't run (needs sudo).
