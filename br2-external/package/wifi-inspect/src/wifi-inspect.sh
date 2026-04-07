#!/bin/sh

set -u

SCRIPT_NAME="wifi-inspect"
SCRIPT_VERSION="1.0"
DEFAULT_INTERFACE="wlan0"
WIFI_DEFAULTS="/etc/default/wifi"
LOG_TO_SYSLOG=0

if [ -r "$WIFI_DEFAULTS" ]; then
	# shellcheck disable=SC1090
	. "$WIFI_DEFAULTS"
fi

WIFI_INTERFACE="${WIFI_INTERFACE:-$DEFAULT_INTERFACE}"

timestamp() {
	date -u +"%Y-%m-%dT%H:%M:%SZ"
}

sanitize_value() {
	printf '%s' "$1" | tr ' ' '_' | tr -cd '[:alnum:]_.,:/@%+=-'
}

emit_log() {
	level="$1"
	event="$2"
	shift 2
	message="$(timestamp) level=${level} component=${SCRIPT_NAME} event=${event}"
	while [ "$#" -gt 0 ]; do
		message="${message} $1"
		shift
	done
	printf '%s\n' "$message"
	if [ "$LOG_TO_SYSLOG" -eq 1 ] && command -v logger >/dev/null 2>&1; then
		case "$level" in
			ERROR) priority="user.err" ;;
			WARN) priority="user.warning" ;;
			INFO) priority="user.notice" ;;
			*) priority="user.debug" ;;
		esac
		logger -t "$SCRIPT_NAME" -p "$priority" -- "$message"
	fi
}

log_info() {
	emit_log INFO "$@"
}

log_warn() {
	emit_log WARN "$@"
}

log_error() {
	emit_log ERROR "$@"
}

usage() {
	cat <<EOF
Usage: $SCRIPT_NAME [--interface IFACE] [--syslog]
EOF
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--interface)
			shift
			[ "$#" -gt 0 ] || {
				log_error argument_missing detail=interface
				exit 2
			}
			WIFI_INTERFACE="$1"
			;;
		--syslog)
			LOG_TO_SYSLOG=1
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			log_error invalid_argument value="$1"
			usage
			exit 2
			;;
	esac
	shift
done

failures=0

detect_wireless_interfaces() {
	for net_path in /sys/class/net/*; do
		[ -d "$net_path" ] || continue
		if [ -d "$net_path/wireless" ]; then
			basename "$net_path"
		fi
	done
}

resolve_wifi_interface() {
	if [ -d "/sys/class/net/${WIFI_INTERFACE}" ]; then
		return 0
	fi

	detected_ifaces="$(detect_wireless_interfaces | paste -sd, -)"
	if [ -n "$detected_ifaces" ]; then
		record_warn configured_interface_missing iface="$WIFI_INTERFACE" detected="$detected_ifaces"
		case "$detected_ifaces" in
			*,*)
				record_fail interface_missing iface="$WIFI_INTERFACE" detected="$detected_ifaces"
				return 1
				;;
			*)
				WIFI_INTERFACE="$detected_ifaces"
				record_warn interface_autodetected iface="$WIFI_INTERFACE"
				return 0
				;;
		esac
	fi

	record_fail interface_missing iface="$WIFI_INTERFACE" detected=none
	return 1
}

check_boot_config_for_wifi_disable() {
	for config_path in /boot/config.txt /boot/firmware/config.txt /boot/rpi-firmware/config.txt; do
		[ -f "$config_path" ] || continue
		if grep -Eq '^[[:space:]]*(dtoverlay=disable-wifi|dtparam=wifi=off)([[:space:]]*(#.*)?)?$' "$config_path"; then
			record_fail wifi_disabled_in_boot_config path="$config_path"
		else
			record_ok boot_config_checked path="$config_path"
		fi
		return
	done

	record_warn boot_config_unavailable
}

record_ok() {
	log_info "$@"
}

record_fail() {
	failures=$((failures + 1))
	log_error "$@"
}

record_warn() {
	log_warn "$@"
}

record_ok script_start version="$SCRIPT_VERSION" iface="$WIFI_INTERFACE"

if [ -f /etc/wpa_supplicant.conf ]; then
	record_ok config_present path=/etc/wpa_supplicant.conf
else
	record_fail config_missing path=/etc/wpa_supplicant.conf
fi

resolve_wifi_interface

wireless_ifaces="$(detect_wireless_interfaces | paste -sd, -)"
if [ -n "$wireless_ifaces" ]; then
	record_ok wireless_interfaces_detected value="$wireless_ifaces"
else
	record_warn wireless_interfaces_missing
fi

if [ -d "/sys/class/net/${WIFI_INTERFACE}" ]; then
	operstate="$(cat "/sys/class/net/${WIFI_INTERFACE}/operstate" 2>/dev/null || echo unknown)"
	address="$(cat "/sys/class/net/${WIFI_INTERFACE}/address" 2>/dev/null || echo unavailable)"
	carrier="$(cat "/sys/class/net/${WIFI_INTERFACE}/carrier" 2>/dev/null || echo unknown)"
	record_ok interface_present iface="$WIFI_INTERFACE" operstate="$operstate" carrier="$carrier" mac="$address"
fi

if command -v ip >/dev/null 2>&1 && [ -d "/sys/class/net/${WIFI_INTERFACE}" ]; then
	ipv4="$(ip -4 -o addr show dev "$WIFI_INTERFACE" 2>/dev/null | awk '{print $4}' | paste -sd, -)"
	ipv6="$(ip -6 -o addr show dev "$WIFI_INTERFACE" scope global 2>/dev/null | awk '{print $4}' | paste -sd, -)"
	[ -n "$ipv4" ] && record_ok ipv4_address iface="$WIFI_INTERFACE" value="$ipv4" || record_warn ipv4_missing iface="$WIFI_INTERFACE"
	[ -n "$ipv6" ] && record_ok ipv6_address iface="$WIFI_INTERFACE" value="$ipv6" || record_warn ipv6_missing iface="$WIFI_INTERFACE"
fi

if command -v iw >/dev/null 2>&1 && [ -d "/sys/class/net/${WIFI_INTERFACE}" ]; then
	iw_link_output="$(iw dev "$WIFI_INTERFACE" link 2>/dev/null)"
	link_status="disconnected"
	link_ssid="unknown"
	link_bssid="unknown"
	link_signal="unknown"

	if printf '%s\n' "$iw_link_output" | grep -q '^Connected to '; then
		link_status="connected"
		link_bssid="$(printf '%s\n' "$iw_link_output" | awk '/^Connected to / { print $3; exit }')"
	fi

	if printf '%s\n' "$iw_link_output" | grep -q '^SSID: '; then
		link_ssid="$(printf '%s\n' "$iw_link_output" | sed -n 's/^SSID: //p' | head -n 1)"
	fi

	if printf '%s\n' "$iw_link_output" | grep -q 'signal:'; then
		link_signal="$(printf '%s\n' "$iw_link_output" | awk '/signal:/ { print $2 $3; exit }')"
	fi

	record_ok link_status iface="$WIFI_INTERFACE" \
		status="$(sanitize_value "$link_status")" \
		bssid="$(sanitize_value "$link_bssid")" \
		ssid="$(sanitize_value "$link_ssid")" \
		signal="$(sanitize_value "$link_signal")"
fi

if pidof wpa_supplicant >/dev/null 2>&1; then
	record_ok wpa_supplicant_running
else
	record_warn wpa_supplicant_not_running
fi

firmware_dir="/lib/firmware/brcm"
if [ -d "$firmware_dir" ]; then
	firmware_files="$(find "$firmware_dir" -maxdepth 1 -type f \( -name 'brcmfmac*.bin' -o -name 'brcmfmac*.txt' -o -name 'brcmfmac*.clm_blob' \) | wc -l)"
	record_ok firmware_files_present directory="$firmware_dir" count="$firmware_files"
else
	record_fail firmware_dir_missing path="$firmware_dir"
fi

if [ -d /sys/module/brcmfmac ]; then
	record_ok kernel_module_loaded module=brcmfmac
else
	record_warn kernel_module_missing module=brcmfmac
fi

if [ -L "/sys/class/net/${WIFI_INTERFACE}/device/driver/module" ]; then
	module_name="$(basename "$(readlink -f "/sys/class/net/${WIFI_INTERFACE}/device/driver/module")")"
	record_ok driver_module iface="$WIFI_INTERFACE" module="$module_name"
	if [ "$module_name" = "brcmfmac" ]; then
		record_ok rpi_wifi_driver_loaded iface="$WIFI_INTERFACE" module="$module_name"
	else
		record_warn unexpected_wifi_driver iface="$WIFI_INTERFACE" module="$module_name"
	fi
else
	record_warn driver_module_unknown iface="$WIFI_INTERFACE"
fi

check_boot_config_for_wifi_disable

if dmesg >/dev/null 2>&1; then
	dmesg_log="$(dmesg 2>/dev/null)"
	if printf '%s\n' "$dmesg_log" | grep -Eq 'brcmfmac:.*using brcm/'; then
		firmware_line="$(printf '%s\n' "$dmesg_log" | grep -E 'brcmfmac:.*using brcm/' | tail -n 1)"
		record_ok firmware_load_confirmed source=dmesg detail="$(sanitize_value "$firmware_line")"
	elif printf '%s\n' "$dmesg_log" | grep -Eq 'brcmfmac|firmware: failed|Direct firmware load.*failed'; then
		error_line="$(printf '%s\n' "$dmesg_log" | grep -E 'brcmfmac|firmware: failed|Direct firmware load.*failed' | tail -n 1)"
		record_fail firmware_load_error source=dmesg detail="$(sanitize_value "$error_line")"
	else
		record_warn firmware_load_unconfirmed source=dmesg
	fi
else
	record_warn dmesg_unavailable
fi

if [ "$failures" -eq 0 ]; then
	record_ok inspection_complete result=pass
	exit 0
fi

log_error inspection_complete result=fail failures="$failures"
exit 1
