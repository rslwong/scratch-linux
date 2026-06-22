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

  # libtool .la sysroot fixup: the .la files were generated with prefix=/usr but
  # live under DESTDIR=$ROOTFS, so their absolute paths (libdir + the inter-lib
  # dependency_libs reference, e.g. libatopology.la -> /usr/lib/libasound.la)
  # point at the host root and libtool can't find them when linking alsa-utils.
  # Rewrite those /usr/lib paths to the rootfs so libtool resolves them.
  sed -i -e "s| /usr/lib/| $ROOTFS/usr/lib/|g" \
         -e "s|^libdir='/usr/lib'|libdir='$ROOTFS/usr/lib'|" \
         "$ROOTFS"/usr/lib/libasound.la "$ROOTFS"/usr/lib/libatopology.la

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
    # -all-static (a libtool flag, not gcc's) at link time forces a fully static
    # binary INCLUDING libc. Plain -static is consumed by libtool to mean "use
    # static libtool libs" and dropped from the gcc command, leaving libc linked
    # dynamically — which assert_static below would (correctly) reject. We keep
    # -static for configure's raw gcc feature tests (gcc rejects -all-static).
    make LDFLAGS=-all-static -j"$JOBS"
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

  # Starter config (no secrets baked in). Fill in on the target, or just run the
  # `wifi-connect` helper below. update_config=1 lets wpa_cli/wifi-connect write
  # a chosen network back here so it persists across reboots.
  [ -f "$ROOTFS/etc/wpa_supplicant.conf" ] || cat > "$ROOTFS/etc/wpa_supplicant.conf" <<'EOF'
ctrl_interface=/var/run/wpa_supplicant
update_config=1
# network={
#     ssid="MYSSID"
#     psk="mypassword"
# }
EOF

  # wifi-connect: guided setup driven entirely by the static tools above
  # (wpa_supplicant/wpa_cli/udhcpc) — the lightweight stand-in for nmtui, with
  # no NetworkManager/D-Bus/glib to cross-build. Scans, shows a numbered menu,
  # prompts for the passphrase, associates, persists, and pulls a DHCP lease.
  mkdir -p "$ROOTFS/usr/sbin"
  cat > "$ROOTFS/usr/sbin/wifi-connect" <<'WIFI_CONNECT'
#!/bin/sh
# wifi-connect [interface]  (default: wlan0)
# Guided wifi setup for this static rootfs: bring the interface up, scan, pick
# an SSID from a menu, enter the passphrase, associate, and get an IP — using
# only wpa_supplicant/wpa_cli/udhcpc (no NetworkManager/nmtui needed).
set -u

IF="${1:-wlan0}"
CONF=/etc/wpa_supplicant.conf
CTRL=/var/run/wpa_supplicant

die()  { echo "wifi-connect: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[ "$(id -u)" = 0 ] || die "must be run as root"
have wpa_supplicant || die "wpa_supplicant not found"
have wpa_cli        || die "wpa_cli not found"
have udhcpc         || die "udhcpc not found"

# Bring the interface up (busybox ip, falling back to ifconfig).
if have ip; then ip link set "$IF" up 2>/dev/null
else ifconfig "$IF" up 2>/dev/null; fi || die "no such interface: $IF"

# Ensure a control-capable wpa_supplicant is running on $IF.
if ! wpa_cli -i "$IF" -p "$CTRL" ping 2>/dev/null | grep -q PONG; then
  echo "Starting wpa_supplicant on $IF ..."
  [ -f "$CONF" ] || die "missing $CONF"
  wpa_supplicant -B -i "$IF" -c "$CONF" \
    || die "failed to start wpa_supplicant (check $CONF and the driver/firmware)"
  sleep 1
fi

echo "Scanning on $IF ..."
wpa_cli -i "$IF" -p "$CTRL" scan >/dev/null 2>&1
sleep 3

# De-duplicated, numbered list of visible SSIDs (+ open/secured from the flags).
tmp=$(mktemp 2>/dev/null || echo "/tmp/wifi.$$")
wpa_cli -i "$IF" -p "$CTRL" scan_results 2>/dev/null \
  | awk -F'\t' 'NR>1 && $5!="" {
        sec = ($4 ~ /WPA|RSN|WEP/) ? "secured" : "open"
        if (!seen[$5]++) printf "%s\t%s\n", $5, sec
    }' > "$tmp"
[ -s "$tmp" ] || { rm -f "$tmp"; die "no networks found (retry, or check firmware/driver)"; }

echo
echo "Available networks:"
i=0
while IFS="$(printf '\t')" read -r ssid sec; do
  i=$((i + 1))
  printf "  %2d) %-32s [%s]\n" "$i" "$ssid" "$sec"
done < "$tmp"
echo

printf "Select a network [1-%d]: " "$i"
read -r n
case "$n" in ''|*[!0-9]*) rm -f "$tmp"; die "invalid selection";; esac
{ [ "$n" -ge 1 ] && [ "$n" -le "$i" ]; } || { rm -f "$tmp"; die "selection out of range"; }

sel=$(sed -n "${n}p" "$tmp")
SSID=$(printf '%s' "$sel" | cut -f1)
SEC=$(printf '%s' "$sel" | cut -f2)
rm -f "$tmp"
echo "Selected: $SSID ($SEC)"

# Configure the chosen network through the control interface.
ID=$(wpa_cli -i "$IF" -p "$CTRL" add_network | tail -n1)
case "$ID" in ''|*[!0-9]*) die "add_network failed";; esac

set_net() {  # key  value (already quoted if it must be a quoted string)
  out=$(wpa_cli -i "$IF" -p "$CTRL" set_network "$ID" "$1" "$2")
  echo "$out" | grep -q OK || die "set_network $1 failed: $out"
}

# wpa_cli expects ssid/psk string values wrapped in literal double quotes.
set_net ssid "\"$SSID\""
if [ "$SEC" = open ]; then
  set_net key_mgmt NONE
else
  stty -echo 2>/dev/null
  printf "Passphrase for %s: " "$SSID"; read -r PSK; echo
  stty echo 2>/dev/null
  [ -n "$PSK" ] || die "empty passphrase"
  set_net psk "\"$PSK\""
fi

wpa_cli -i "$IF" -p "$CTRL" enable_network "$ID" >/dev/null
wpa_cli -i "$IF" -p "$CTRL" select_network "$ID" >/dev/null

printf "Associating"
state=""
t=0
while [ "$t" -lt 15 ]; do
  state=$(wpa_cli -i "$IF" -p "$CTRL" status 2>/dev/null | sed -n 's/^wpa_state=//p')
  [ "$state" = COMPLETED ] && break
  printf "."; sleep 1; t=$((t + 1))
done
echo
[ "$state" = COMPLETED ] || die "association failed (wrong passphrase or out of range)"

# Persist for next boot when the config allows it (update_config=1).
if grep -q '^update_config=1' "$CONF" 2>/dev/null; then
  wpa_cli -i "$IF" -p "$CTRL" save_config >/dev/null 2>&1 \
    && echo "Saved network to $CONF"
fi

echo "Requesting DHCP lease ..."
udhcpc -i "$IF" -n -q || die "DHCP failed (associated, but no lease)"

echo "Connected on $IF."
if have ip; then ip -4 addr show "$IF" | sed -n 's/.*inet \([0-9.]*\).*/  IP: \1/p'
else ifconfig "$IF" | sed -n 's/.*inet addr:\([0-9.]*\).*/  IP: \1/p'; fi
WIFI_CONNECT
  chmod +x "$ROOTFS/usr/sbin/wifi-connect"

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
        Connect on the target — guided (scan, pick, passphrase, DHCP):
          wifi-connect              # or: wifi-connect wlan1
        ...or by hand:
          wpa_passphrase MYSSID 'pass' >> /etc/wpa_supplicant.conf
          wpa_supplicant -B -i wlan0 -c /etc/wpa_supplicant.conf
          udhcpc -i wlan0
EOF
fi
