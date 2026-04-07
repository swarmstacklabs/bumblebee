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
