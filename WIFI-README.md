# Adding USB wifi dongle support

The build already covers the two wifi drivers compiled into the kernel
(`iwlwifi` for Intel, `ath9k` for Atheros PCIe). A USB wifi dongle from another
chip family needs **its driver added to the kernel** *and* **its firmware
bundled**. This is a four-step loop; the only real work is identifying the chip.

> Toggles: wifi lives behind `NET=1`, set on every step that uses it
> (`02-kernel.sh`, `03-rootfs.sh`, `04-apps.sh`). See the main
> [README](README.md) "Optional features" section.

## 1. Identify the chip (not the brand on the box)

The marketing name is useless; you need the **USB VID:PID → chip family**. Plug
the dongle into any Linux box (the Lima VM works) and:

```sh
lsusb                    # e.g. "0bda:8179 Realtek RTL8188EUS"
# or, if a driver already half-loads:
dmesg | grep -i firmware # exact path it asked for, e.g. "rtlwifi/rtl8188eufw.bin"
```

That `dmesg` line is gold — it tells you the **exact firmware filename** the
driver wants, which removes all guesswork from step 3.

## 2. Add the driver to `02-kernel.sh` (built-in, `=y`)

Add the matching `--enable` to the `WLAN` block of `02-kernel.sh`. No module
loader on this system, so it must be built **in**, not as a module.

| Chip family (examples) | Kernel option(s) | Firmware path in `/lib/firmware` |
|---|---|---|
| Realtek RTL8188CU/8192CU/8188EU/8723 | `RTL8XXXU` | `rtlwifi/*` |
| Realtek RTL8811/8821/8822 CU (AC) | `RTW88` `RTW88_USB` `RTW88_8821CU` (etc.) | `rtw88/*` |
| Ralink/MediaTek RT2870/RT3070/RT5370 | `RT2800USB` (+`RT2800USB_RT53XX` etc.) | `rt2*.bin rt3*.bin` |
| MediaTek MT7601U | `MT7601U` | `mediatek/mt7601u.bin` (older: `mt7601u.bin`) |
| MediaTek MT7612U/7921U (AC/AX) | `MT76x2U` / `MT7921U` | `mediatek/*` |
| Atheros AR9271/AR7010 (USB ath9k) | `ATH9K_HTC` | `ath9k_htc/*` |

Example — Realtek RTL8188EUS, added to the `WLAN` block:

```sh
    --enable WLAN_VENDOR_REALTEK --enable RTL8XXXU \
```

`make olddefconfig` (already in the script) pulls in any parent symbols the
option depends on.

## 3. Add the firmware to `FW_LIST`

`04-apps.sh` sparse-fetches from `linux-firmware`. Add the path pattern from the
table (or from your `dmesg` line) when you run it:

```sh
FW_LIST='/iwlwifi-* /rtlwifi/*' NET=1 AUDIO=1 ./04-apps.sh
```

For built-in drivers this half is **required** — the chip won't even appear as
`wlan0` until the blob is in `/lib/firmware` (which lives in the
initramfs/rootfs, so it is present at probe time).

`FW_LIST` patterns are gitignore-style, rooted at the top of the firmware tree.
To skip the download and use a local firmware tree instead: `FW_DIR=/path/to/tree`.

## 4. Rebuild the affected pieces

```sh
NET=1 AUDIO=1 ./02-kernel.sh         # new driver compiled in
FW_LIST='...' NET=1 ./04-apps.sh      # new firmware bundled
# then rebuild the image (initramfs cpio, or ./last-usb.sh)
```

## Verify on the target

```sh
dmesg | grep -i firmware             # loaded, NOT "failed to load"
ip link                              # wlan0 should now exist
```

Then associate and get an address:

```sh
wpa_passphrase MYSSID 'mypassword' >> /etc/wpa_supplicant.conf
wpa_supplicant -B -i wlan0 -c /etc/wpa_supplicant.conf
udhcpc -i wlan0
```

## Two failure modes (both visible in `dmesg`)

- **Driver missing** — no `wlan0`, nothing in `dmesg` about the device → fix step 2.
- **Firmware missing** — `Direct firmware load for … failed` → fix step 3.

## Limits of this setup

`wpa_supplicant` here is built with the **wext driver + internal crypto** (no
libnl/openssl), which does **WPA2-PSK** (home wifi). WPA-Enterprise or
nl80211-only drivers need `CONFIG_DRIVER_NL80211` + libnl + openssl added to the
`04-apps.sh` build. Realtek AC chips like RTL8812AU often need an out-of-tree
driver (not in mainline `linux-firmware`/kernel) — those are out of scope here.
