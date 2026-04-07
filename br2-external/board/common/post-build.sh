#!/usr/bin/env bash
set -euo pipefail
TARGET_DIR="$1"

mkdir -p "$TARGET_DIR/etc" "$TARGET_DIR/root" "$TARGET_DIR/usr/share/doc/project"
mkdir -p "$TARGET_DIR/var"

rm -rf "$TARGET_DIR/var/run"
ln -s ../run "$TARGET_DIR/var/run"

HOSTNAME_PREFIX="${HOSTNAME_PREFIX:-bumblebee}"
HOSTNAME_VALUE="${HOSTNAME:-}"
WIFI_SSID="${WIFI_SSID:-}"
WIFI_PSK="${WIFI_PSK:-}"
WIFI_COUNTRY="${WIFI_COUNTRY:-LT}"
WIFI_INTERFACE="${WIFI_INTERFACE:-wlan0}"
BOARD_NAME="$(basename "$(dirname "$TARGET_DIR")")"

if [[ -z "$HOSTNAME_VALUE" ]]; then
  HOSTNAME_VALUE="${HOSTNAME_PREFIX}-${BOARD_NAME}"
fi

cat > "$TARGET_DIR/etc/hostname" <<HOSTNAME
${HOSTNAME_VALUE}
HOSTNAME

cat > "$TARGET_DIR/etc/motd" <<'MOTD'
Welcome to the Bumblebee Raspberry Pi.
SSH is enabled through Dropbear.
Wi-Fi packages and Raspberry Pi firmware are included.
MOTD

if [[ -n "$WIFI_SSID" && -n "$WIFI_PSK" ]]; then
  mkdir -p "$TARGET_DIR/etc/default"
  cat > "$TARGET_DIR/etc/default/wifi" <<WIFIENV
WIFI_INTERFACE="${WIFI_INTERFACE}"
WIFI_COUNTRY="${WIFI_COUNTRY}"
WIFI_HOSTNAME="${HOSTNAME_VALUE}"
WIFIENV
  chmod 600 "$TARGET_DIR/etc/default/wifi"

  cat > "$TARGET_DIR/etc/wpa_supplicant.conf" <<WPA
update_config=1
country=${WIFI_COUNTRY}
network={
    ssid="$WIFI_SSID"
    psk="$WIFI_PSK"
}
WPA
  chmod 600 "$TARGET_DIR/etc/wpa_supplicant.conf"
fi

cat > "$TARGET_DIR/usr/share/doc/project/first-boot.txt" <<'DOC'
Welcome to the Bumblebee Raspberry Pi:
- Dropbear SSH enabled in defconfig
- Wi-Fi firmware/packages enabled in defconfig
- Optional /etc/wpa_supplicant.conf generated if WIFI_SSID and WIFI_PSK are set
- Wi-Fi runtime defaults generated in /etc/default/wifi
DOC
