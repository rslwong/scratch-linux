#!/bin/sh
# Add extra userspace apps + firmware so the booted USB detects and uses sound
# and wifi. Gated by the same toggles as the kernel/init (config.sh):
#   AUDIO=1  ALSA userspace (alsa-lib + alsa-utils) -> aplay / amixer / alsactl
#   NET=1    wifi: wpa_supplicant + bundled firmware for the built-in drivers
# Static cross-compiled binaries, like BusyBox — the target has no C library.
# Run AFTER 01..03, BEFORE last-usb.sh. Re-runnable.
#
# wpa_supplicant uses the wext driver + internal crypto: no libnl/openssl to
# cross-build. Does WPA2-PSK (home wifi). ponytail: add CONFIG_DRIVER_NL80211 +
# libnl + openssl when you need WPA-Enterprise or nl80211-only drivers.
set -eu
. "$(dirname "$0")/config.sh"

[ -x "$ROOTFS/bin/busybox" ] || { echo "Run ./03-rootfs.sh first (no rootfs at $ROOTFS)"; exit 1; }
[ "$NET" = 1 ] || [ "$AUDIO" = 1 ] || { echo "Nothing to do: set AUDIO=1 and/or NET=1"; exit 0; }

CC="${CROSS_COMPILE}gcc"
HOST="${CROSS_COMPILE%-}"          # e.g. x86_64-linux-gnu- -> x86_64-linux-gnu
HOST="${HOST:-x86_64-linux-gnu}"
cd "$SRC"

fetch() { [ -f "$2" ] || wget -O "$2" "$1"; }       # url, file
unpack() { [ -d "$2" ] || tar xf "$1"; }            # tarball, dir

# Fail loudly if a "static" binary ended up dynamically linked — it would just
# crash on the libc-less target. This is the check that matters here.
assert_static() {
  if readelf -d "$1" 2>/dev/null | grep -q NEEDED; then
    echo "ERROR: $1 is dynamically linked — target has no libc"; exit 1
  fi
}

# --- audio: alsa-lib + alsa-utils -------------------------------------------
if [ "$AUDIO" = 1 ]; then
  AV=1.2.11
  # alsa-lib installed into the rootfs: gives us the static libasound.a to link
  # against AND the runtime config (/usr/share/alsa/alsa.conf) aplay needs.
  fetch "https://www.alsa-project.org/files/pub/lib/alsa-lib-$AV.tar.bz2" "alsa-lib-$AV.tar.bz2"
  unpack "alsa-lib-$AV.tar.bz2" "alsa-lib-$AV"
  ( cd "alsa-lib-$AV"
    ./configure --host="$HOST" --prefix=/usr --enable-static --disable-shared \
      --disable-python CC="$CC"
    make -j"$JOBS"
    make install DESTDIR="$ROOTFS" )

  # alsa-utils linked statically against that libasound.a. Drop alsamixer (needs
  # ncurses) and nls (needs gettext) so there's nothing else to cross-build.
  fetch "https://www.alsa-project.org/files/pub/utils/alsa-utils-$AV.tar.bz2" "alsa-utils-$AV.tar.bz2"
  unpack "alsa-utils-$AV.tar.bz2" "alsa-utils-$AV"
  ( cd "alsa-utils-$AV"
    PKG_CONFIG_PATH="$ROOTFS/usr/lib/pkgconfig" PKG_CONFIG_SYSROOT_DIR="$ROOTFS" \
    ./configure --host="$HOST" --prefix=/usr \
      --with-alsa-prefix="$ROOTFS/usr/lib" --with-alsa-inc-prefix="$ROOTFS/usr/include" \
      --disable-alsamixer --disable-nls --disable-bat --disable-xmlto --disable-rst2man \
      CC="$CC" LDFLAGS=-static
    make -j"$JOBS"
    make install DESTDIR="$ROOTFS" )

  # Strip the build-only bits we just dragged into the target (it runs static
  # binaries; it needs no headers, .a, or pkgconfig). Keep /usr/share/alsa.
  rm -rf "$ROOTFS/usr/include" "$ROOTFS/usr/lib/pkgconfig" "$ROOTFS"/usr/lib/libasound.* \
         "$ROOTFS/usr/share/man"
  assert_static "$ROOTFS/usr/bin/aplay"
  echo "audio -> aplay/amixer/alsactl installed (list cards: aplay -l; play: aplay file.wav)"
fi

# --- wifi: wpa_supplicant + firmware ----------------------------------------
if [ "$NET" = 1 ]; then
  WV=2.10
  fetch "https://w1.fi/releases/wpa_supplicant-$WV.tar.gz" "wpa_supplicant-$WV.tar.gz"
  unpack "wpa_supplicant-$WV.tar.gz" "wpa_supplicant-$WV"
  ( cd "wpa_supplicant-$WV/wpa_supplicant"
    cat > .config <<'EOF'
CONFIG_DRIVER_WEXT=y
CONFIG_CTRL_IFACE=y
CONFIG_BACKEND=file
CONFIG_TLS=internal
CONFIG_INTERNAL_LIBTOMMATH=y
EOF
    make clean >/dev/null 2>&1 || true
    make CC="$CC" LDFLAGS=-static -j"$JOBS" wpa_supplicant wpa_cli wpa_passphrase
    mkdir -p "$ROOTFS/usr/sbin"
    cp wpa_supplicant wpa_cli wpa_passphrase "$ROOTFS/usr/sbin/" )
  for b in wpa_supplicant wpa_cli wpa_passphrase; do assert_static "$ROOTFS/usr/sbin/$b"; done

  # Starter config (no secrets baked in). Fill in on the target, or regenerate:
  #   wpa_passphrase MYSSID 'pass' >> /etc/wpa_supplicant.conf
  [ -f "$ROOTFS/etc/wpa_supplicant.conf" ] || cat > "$ROOTFS/etc/wpa_supplicant.conf" <<'EOF'
ctrl_interface=/var/run/wpa_supplicant
# network={
#     ssid="MYSSID"
#     psk="mypassword"
# }
EOF

  # Firmware. Most wifi chips load a blob at probe time or they don't appear at
  # all. We bundle the blobs for the drivers built into the kernel (02). Default
  # = iwlwifi (Intel, the common laptop/mini-PC card; ath9k PCIe needs none).
  # Extend by exporting FW_LIST (gitignore-style patterns), e.g.
  #   FW_LIST='/iwlwifi-* /ath9k_htc/* /rtw88/*'
  # or skip the download entirely with FW_DIR=/path/to/a/firmware/tree.
  mkdir -p "$ROOTFS/lib/firmware"
  if [ -n "${FW_DIR:-}" ] && [ -d "$FW_DIR" ]; then
    tar -C "$FW_DIR" --exclude=.git -cf - . | tar -C "$ROOTFS/lib/firmware" -xf -
    echo "wifi  -> wpa_supplicant installed; firmware copied from $FW_DIR"
  else
    FW_LIST="${FW_LIST:-/iwlwifi-*}"
    repo="$SRC/linux-firmware"
    if [ ! -d "$repo/.git" ]; then
      # blob:none + sparse: fetch only the blobs we list, not the whole ~2GB tree.
      git clone --depth 1 --filter=blob:none --no-checkout \
        https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git "$repo"
    fi
    ( cd "$repo"
      git sparse-checkout init --no-cone
      git sparse-checkout set $FW_LIST
      git checkout
      tar --exclude=.git -cf - . | tar -C "$ROOTFS/lib/firmware" -xf - )
    echo "wifi  -> wpa_supplicant installed; firmware bundled ($FW_LIST)"
  fi
  cat <<'EOF'
        Connect on the target (wlan0 brought up at boot; associate + DHCP):
          wpa_passphrase MYSSID 'pass' >> /etc/wpa_supplicant.conf
          wpa_supplicant -B -i wlan0 -c /etc/wpa_supplicant.conf
          udhcpc -i wlan0
EOF
fi
