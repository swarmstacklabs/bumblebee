# Buildroot Raspberry Pi multi-target skeleton v2

This version is focused on **Raspberry Pi 4 Model B** and also supports **rpi3** and **rpi5**.

## Added in v2

- `.env.example` for local configuration
- `make env-file` to generate `.env`
- pre-enabled SSH through Dropbear
- Wi-Fi firmware and userland packages enabled in per-target defconfigs
- generated Wi-Fi config using `WIFI_SSID`, `WIFI_PSK`, `WIFI_COUNTRY`, and `WIFI_INTERFACE`
- `wifi-inspect` diagnostic utility with structured logs for Wi-Fi and Raspberry Pi firmware checks
- `custom-app` package template in `br2-external/package/custom-app`
- `lorawan-server` Zig package in `br2-external/package/lorawan-server`
- `show-image` helper target
- improved SD burn workflow using `.env` defaults

## Quick start

```bash
cp .env.example .env
# edit .env
make defconfig
make menuconfig
make build
make burn
```

## Example `.env`

```bash
BUILDROOT_DIR=../buildroot
TARGET=rpi4
DEVICE=/dev/sdX
TTY_BAUD=115200
HOSTNAME_PREFIX=bumblebee
HOSTNAME=bumblebee
WIFI_COUNTRY=LT
WIFI_INTERFACE=wlan0
WIFI_SSID=mywifi
WIFI_PSK=supersecret
```

## Main targets

```bash
make defconfig
make menuconfig
make build
make show-image
make burn
make tty
make TARGET=rpi3 build
make TARGET=rpi5 menuconfig
```

## Notes

- `LD_LIBRARY_PATH` and `DYLD_LIBRARY_PATH` are removed for Buildroot calls.
- `custom-app` is only a template package. Replace it with your own service or binary.
- `lorawan-server` builds a Zig UDP daemon and currently expects `zig` to be installed on the build host and available on `PATH`.
- `lorawan-server` now listens on UDP `1700` and exposes an HTTP CRUD API for devices on TCP `8080`.
- If `WIFI_SSID` and `WIFI_PSK` are set, the build generates `/etc/wpa_supplicant.conf` and `/etc/default/wifi`.
- Set `HOSTNAME=bumblebee` in `.env` if you want the device to advertise the exact DHCP hostname `bumblebee` instead of the default board-suffixed hostname.
- The generated `wpa_supplicant.conf` is kept compatible with the current Buildroot `wpa_supplicant` feature set and does not require `ctrl_interface` support.
- `S40network-extra` starts `wpa_supplicant` automatically on boot, auto-detects a single wireless netdev when the kernel does not use `wlan0`, waits for association, and then starts `udhcpc` to obtain an IP address.
- `S00filesystems` mounts `/proc`, `/sys`, `/run`, `/tmp`, `/dev/pts`, and `/dev/shm` early in boot so module loading and interface discovery work reliably.
- `brcmfmac` is queued through `/etc/modules-load.d` so Raspberry Pi SDIO Wi-Fi probes even if module autoloading is incomplete.
- Run `wifi-inspect` on the target to validate interface state, IP assignment, detected wireless interfaces, driver/module binding, boot config Wi-Fi state, and `brcmfmac` firmware load status.
- Keep local credentials in `.env`; the project ignores that file.
- The burn script still asks for `YES` before writing the image to the SD card.
- `rpi4` starts login shells on both local HDMI/keyboard (`tty1`) and the serial console (`ttyAMA0` at `115200`).
- The `rpi4` firmware config enables UART explicitly with `enable_uart=1` and routes Bluetooth to the mini UART so the serial console stays on `ttyAMA0`.
- `make tty` auto-detects common host serial adapters (`/dev/ttyUSB*`, `/dev/ttyACM*`) and opens them with `screen`. Override `TTY_DEVICE` and `TTY_BAUD` as needed.

## Inspect WI-FI

```sh
wifi-inspect --syslog
dmesg | grep -E 'brcmfmac|firmware'
lsmod | grep -E 'brcmfmac|brcmutil|cfg80211|rfkill'
ip link show wlan0
```
Manuall set up

```sh
mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sysfs /sys 2>/dev/null || true
mount -o remount,rw / 2>/dev/null || true

ip link set wlan0 up
wpa_supplicant -B -i wlan0 -c /etc/wpa_supplicant.conf
udhcpc -i wlan0 -q -n
```

## Buildroot: Why Some Directories Are Not Mounted Automatically

Buildroot does not behave like full Linux distributions (e.g., Ubuntu, Fedora).  
It generates a **minimal root filesystem**, so mounts must be explicitly configured.

---

### 1. Minimal Init System

Buildroot typically uses:
- BusyBox init (`/sbin/init`)
- Minimal `/etc/inittab`

There is no automatic mounting like in systemd-based systems.

👉 Result: `/proc`, `/sys`, `/dev`, `/run` may not be mounted.

---

### 2. Missing `/etc/fstab`

If `fstab` is not present or incomplete, nothing gets mounted automatically.

#### Example:
```bash
proc     /proc    proc     defaults  0 0
sysfs    /sys     sysfs    defaults  0 0
devtmpfs /dev     devtmpfs mode=0755 0 0
tmpfs    /run     tmpfs    defaults  0 0


#### What missing in lorawan

What is in place:

LoRaWAN PHYPayload decode for join requests and uplink/downlink data frames.
AES-128/CMAC-based MIC verification, session key derivation, payload ciphering, join-accept encode, and unicast downlink encode.
MAC command parse/encode for the command set that existed in bumblebee_mac_commands.erl.
SQLite-backed lookup/update for gateways, networks, devices, and nodes using the existing *_json columns.
UDP integration that logs lorawan_join_request and lorawan_uplink events and emits join-accept / basic MAC-response downlinks.
What is still not fully ported from the Erlang behavior:

Full profile / group model and the complete join policy from bumblebee_mac.erl.
ADR state machine, RX window enforcement, duty-cycle handling, and the richer node-health/devstat logic.
Full parity for all inbound MAC-command side effects; right now the automatic downlink responses are intentionally narrow.
Verification:

zig build in br2-external/package/lorawan-server/src
zig test src/lorawan.zig in br2-external/package/lorawan-server/src
The main residual risk is data-shape assumptions in src/lorawan/repository.zig (line 30): the new service expects network_json, gateway_json, and node_json fields such as netid, rxwin_init, and tx_rfch to exist or fall back cleanly. The next step should be porting the remaining profile/group/node policy logic and exposing CRUD for networks/nodes/gateways so the new package has explicit config instead of inferred JSON defaults.



### LoRaWAN API quick setup (curl)

If Basic auth is enabled, set credentials and use `-u "$API_USER:$API_PASS"` in each request.

```bash
API_BASE="http://127.0.0.1:8080"
API_USER="admin"
API_PASS="admin"
```

Create a network (required for LoRaWAN ingest):

```bash
curl -sS -u "$API_USER:$API_PASS" \
  -H "Content-Type: application/json" \
  -X POST "$API_BASE/api/networks" \
  -d '{
    "name": "eu-net",
    "region": "EU868",
    "netid": "000001",
    "tx_codr": "4/5",
    "join1_delay": 5,
    "rx1_delay": 1,
    "gw_power": 14,
    "rxwin_init": {
      "rx1_dr_offset": 0,
      "rx2_data_rate": 0,
      "frequency": 869.525
    },
    "cflist": [867.1, 867.3, 867.5]
  }'
```

Register a gateway:

```bash
curl -sS -u "$API_USER:$API_PASS" \
  -H "Content-Type: application/json" \
  -X POST "$API_BASE/api/gateways" \
  -d '{
    "mac": "aabbccddeeff0011",
    "name": "gw-1",
    "network_name": "eu-net",
    "tx_rfch": 0
  }'
```

Register a device:

```bash
curl -sS -u "$API_USER:$API_PASS" \
  -H "Content-Type: application/json" \
  -X POST "$API_BASE/api/devices" \
  -d '{
    "name": "dev-1",
    "dev_eui": "0011223344556677",
    "app_eui": "8899aabbccddeeff",
    "app_key": "00112233445566778899aabbccddeeff"
  }'
```

Verify created entities:

```bash
curl -sS -u "$API_USER:$API_PASS" "$API_BASE/api/networks"
curl -sS -u "$API_USER:$API_PASS" "$API_BASE/api/gateways"
curl -sS -u "$API_USER:$API_PASS" "$API_BASE/api/devices"
```

For packet-level ingest logs from gateway/device traffic, start the server with:

```bash
LORAWAN_SERVER_LOG_LEVEL=debug
```
