PROJECT_NAME := bumblebee-rpi
ENV_FILE ?= .env

ifneq (,$(wildcard $(ENV_FILE)))
include $(ENV_FILE)
export
endif

BUILDROOT_DIR ?= $(abspath ../buildroot)
BR2_EXTERNAL := $(CURDIR)/br2-external
TARGET ?= rpi4
DEVICE ?=
TTY_DEVICE ?=
TTY_BAUD ?= 115200

OUTPUT_BASE := $(CURDIR)/output
DL_DIR ?= $(CURDIR)/dl
CCACHE_DIR ?= $(CURDIR)/ccache
DL_DIR_ABS := $(abspath $(DL_DIR))
CCACHE_DIR_ABS := $(abspath $(CCACHE_DIR))
HOSTNAME_PREFIX ?= bumblebee
HOSTNAME ?=
WIFI_SSID ?=
WIFI_PSK ?=
WIFI_COUNTRY ?= LT
WIFI_INTERFACE ?= wlan0

SUPPORTED_TARGETS := rpi3 rpi4 rpi5

TARGET_DEFCONFIG_rpi3 := raspberrypi3_64_defconfig
TARGET_DEFCONFIG_rpi4 := raspberrypi4_64_defconfig
TARGET_DEFCONFIG_rpi5 := raspberrypi5_defconfig

OUTPUT_DIR = $(OUTPUT_BASE)/$(TARGET)
OFFICIAL_DEFCONFIG = $(TARGET_DEFCONFIG_$(TARGET))
PROJECT_DEFCONFIG = $(CURDIR)/configs/$(TARGET)_defconfig
BUILDROOT_MAKE = env -u LD_LIBRARY_PATH -u DYLD_LIBRARY_PATH \
	PATH="$(PATH)" \
	WIFI_SSID="$(WIFI_SSID)" WIFI_PSK="$(WIFI_PSK)" \
	WIFI_COUNTRY="$(WIFI_COUNTRY)" WIFI_INTERFACE="$(WIFI_INTERFACE)" \
	HOSTNAME_PREFIX="$(HOSTNAME_PREFIX)" HOSTNAME="$(HOSTNAME)" \
	$(MAKE) -C $(BUILDROOT_DIR) O=$(OUTPUT_DIR) BR2_EXTERNAL=$(BR2_EXTERNAL)

.DEFAULT_GOAL := help

.PHONY: help check-buildroot check-target check-tty-tool check-output-relocated print-vars defconfig menuconfig build clean distclean \
        savedefconfig burn tty shell images env-file list-targets show-image lorawan-host-build lorawan-host-run \
        rpi3 rpi4 rpi5

help:
	@echo "Buildroot multi-target project skeleton v2"
	@echo
	@echo "Common usage:"
	@echo "  cp .env.example .env"
	@echo "  make defconfig"
	@echo "  make menuconfig"
	@echo "  make build"
	@echo "  make burn"
	@echo "  make tty"
	@echo
	@echo "Examples with explicit target:"
	@echo "  make TARGET=rpi4 defconfig"
	@echo "  make TARGET=rpi4 build"
	@echo "  make TARGET=rpi4 burn DEVICE=/dev/sdX"
	@echo "  make tty TTY_DEVICE=/dev/ttyUSB0 TTY_BAUD=115200"
	@echo
	@echo "Other targets:"
	@echo "  make rpi3 defconfig"
	@echo "  make rpi5 build"
	@echo "  make lorawan-host-build"
	@echo "  make lorawan-host-run"
	@echo
	@echo "Config file: $(ENV_FILE)"

rpi3 rpi4 rpi5:
	@$(MAKE) TARGET=$@ $(filter-out $@,$(MAKECMDGOALS))

list-targets:
	@printf '%s\n' $(SUPPORTED_TARGETS)

check-target:
	@if [ -z "$(OFFICIAL_DEFCONFIG)" ]; then \
		echo "Unsupported TARGET='$(TARGET)'. Use one of: $(SUPPORTED_TARGETS)"; \
		exit 1; \
	fi

check-buildroot:
	@if [ ! -f "$(BUILDROOT_DIR)/Makefile" ]; then \
		echo "BUILDROOT_DIR does not look like a Buildroot tree: $(BUILDROOT_DIR)"; \
		echo "Set it in .env or pass BUILDROOT_DIR=/path/to/buildroot"; \
		exit 1; \
	fi

print-vars: check-target
	@echo "TARGET=$(TARGET)"
	@echo "OFFICIAL_DEFCONFIG=$(OFFICIAL_DEFCONFIG)"
	@echo "PROJECT_DEFCONFIG=$(PROJECT_DEFCONFIG)"
	@echo "OUTPUT_DIR=$(OUTPUT_DIR)"
	@echo "BUILDROOT_DIR=$(BUILDROOT_DIR)"
	@echo "BR2_EXTERNAL=$(BR2_EXTERNAL)"
	@echo "DEVICE=$(DEVICE)"
	@echo "TTY_DEVICE=$(TTY_DEVICE)"
	@echo "TTY_BAUD=$(TTY_BAUD)"
	@echo "DL_DIR=$(DL_DIR_ABS)"
	@echo "CCACHE_DIR=$(CCACHE_DIR_ABS)"
	@echo "HOSTNAME_PREFIX=$(HOSTNAME_PREFIX)"
	@echo "HOSTNAME=$(HOSTNAME)"
	@echo "WIFI_SSID=$(WIFI_SSID)"
	@echo "WIFI_COUNTRY=$(WIFI_COUNTRY)"
	@echo "WIFI_INTERFACE=$(WIFI_INTERFACE)"

check-tty-tool:
	@if ! command -v screen >/dev/null 2>&1; then \
		echo "'screen' is required for 'make tty' but is not installed"; \
		exit 1; \
	fi

check-output-relocated: check-target
	@if [ -f "$(OUTPUT_DIR)/host/bin/fakeroot" ] && ! grep -Fq "$(OUTPUT_DIR)/host" "$(OUTPUT_DIR)/host/bin/fakeroot"; then \
		echo "Detected a relocated Buildroot output tree for $(TARGET)."; \
		echo "The host tools under $(OUTPUT_DIR) still point at an older absolute path."; \
		echo "Recreate the output tree under the current workspace path:"; \
		echo "  make TARGET=$(TARGET) distclean"; \
		echo "  make TARGET=$(TARGET) defconfig"; \
		echo "  make TARGET=$(TARGET) build"; \
		exit 1; \
	fi


defconfig: check-buildroot check-target
	@mkdir -p "$(OUTPUT_DIR)" "$(DL_DIR_ABS)" "$(CCACHE_DIR_ABS)"
	@echo "==> Loading upstream defconfig: $(OFFICIAL_DEFCONFIG)"
	@$(BUILDROOT_MAKE) $(OFFICIAL_DEFCONFIG)
	@if [ -f "$(PROJECT_DEFCONFIG)" ]; then \
		echo "==> Applying project defconfig overlay: $(PROJECT_DEFCONFIG)"; \
		cat "$(PROJECT_DEFCONFIG)" >> "$(OUTPUT_DIR)/.config"; \
		$(BUILDROOT_MAKE) olddefconfig BR2_DL_DIR=$(DL_DIR_ABS) BR2_CCACHE_DIR=$(CCACHE_DIR_ABS); \
		cp "$(OUTPUT_DIR)/.config" "$(OUTPUT_DIR)/.config.merged"; \
	fi

menuconfig: check-buildroot check-target check-output-relocated
	@if [ ! -f "$(OUTPUT_DIR)/.config" ]; then \
		echo "No .config yet for $(TARGET). Running defconfig first."; \
		$(MAKE) TARGET=$(TARGET) defconfig BUILDROOT_DIR=$(BUILDROOT_DIR); \
	fi
	$(BUILDROOT_MAKE) menuconfig BR2_DL_DIR=$(DL_DIR_ABS) BR2_CCACHE_DIR=$(CCACHE_DIR_ABS)

build: check-buildroot check-target check-output-relocated
	@if [ ! -f "$(OUTPUT_DIR)/.config" ]; then \
		echo "No .config yet for $(TARGET). Running defconfig first."; \
		$(MAKE) TARGET=$(TARGET) defconfig BUILDROOT_DIR=$(BUILDROOT_DIR); \
	fi
	$(BUILDROOT_MAKE) BR2_DL_DIR=$(DL_DIR_ABS) BR2_CCACHE_DIR=$(CCACHE_DIR_ABS)

savedefconfig: check-buildroot check-target
	@if [ ! -f "$(OUTPUT_DIR)/.config" ]; then \
		echo "Nothing to save. Run menuconfig/build first."; \
		exit 1; \
	fi
	$(BUILDROOT_MAKE) savedefconfig
	@cp "$(OUTPUT_DIR)/defconfig" "$(PROJECT_DEFCONFIG)"
	@echo "Saved $(PROJECT_DEFCONFIG)"

clean: check-buildroot check-target
	@if [ -d "$(OUTPUT_DIR)" ]; then \
		$(BUILDROOT_MAKE) clean; \
	else \
		echo "Nothing to clean for $(TARGET)"; \
	fi

distclean: check-target
	@rm -rf "$(OUTPUT_DIR)"
	@echo "Removed $(OUTPUT_DIR)"

images: check-target
	@find "$(OUTPUT_DIR)/images" -maxdepth 1 -type f 2>/dev/null || true

show-image: check-target
	@OUTPUT_DIR="$(OUTPUT_DIR)" "$(CURDIR)/scripts/find-image.sh"

burn: check-target
	@DEVICE="$(DEVICE)" OUTPUT_DIR="$(OUTPUT_DIR)" TARGET="$(TARGET)" \
		"$(CURDIR)/scripts/burn-sdcard.sh"

tty: check-tty-tool
	@TTY_DEVICE_RESOLVED="$(TTY_DEVICE)"; \
	if [ -z "$$TTY_DEVICE_RESOLVED" ]; then \
		for candidate in /dev/ttyUSB0 /dev/ttyUSB1 /dev/ttyUSB2 /dev/ttyUSB3 /dev/ttyACM0 /dev/ttyACM1; do \
			if [ -e "$$candidate" ]; then \
				TTY_DEVICE_RESOLVED="$$candidate"; \
				break; \
			fi; \
		done; \
	fi; \
	if [ -z "$$TTY_DEVICE_RESOLVED" ]; then \
		echo "No serial adapter found. Checked: /dev/ttyUSB0 /dev/ttyUSB1 /dev/ttyUSB2 /dev/ttyUSB3 /dev/ttyACM0 /dev/ttyACM1"; \
		echo "Plug in the USB-UART adapter or run: make tty TTY_DEVICE=/dev/ttyUSB0"; \
		exit 1; \
	fi; \
	if [ ! -e "$$TTY_DEVICE_RESOLVED" ]; then \
		echo "Serial device not found: $$TTY_DEVICE_RESOLVED"; \
		echo "Check the adapter path with: ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null"; \
		exit 1; \
	fi; \
	if [ ! -r "$$TTY_DEVICE_RESOLVED" ] || [ ! -w "$$TTY_DEVICE_RESOLVED" ]; then \
		echo "No access to $$TTY_DEVICE_RESOLVED"; \
		echo "Check device permissions with: ls -l $$TTY_DEVICE_RESOLVED"; \
		echo "You may need to join the 'dialout' group and log in again"; \
		exit 1; \
	fi; \
	echo "==> Opening $$TTY_DEVICE_RESOLVED at $(TTY_BAUD) baud"; \
	echo "==> Exit with: Ctrl-A then \\"; \
	screen "$$TTY_DEVICE_RESOLVED" "$(TTY_BAUD)"

env-file:
	@if [ -f .env ]; then \
		echo ".env already exists"; \
	else \
		cp .env.example .env; \
		echo "Created .env from .env.example"; \
	fi

shell:
	@env -u LD_LIBRARY_PATH -u DYLD_LIBRARY_PATH bash

lorawan-host-build:
	@mkdir -p "$(OUTPUT_BASE)/lorawan-host"
	@cd "$(CURDIR)/br2-external/package/lorawan-server/src" && \
		ZIG_LOCAL_CACHE_DIR="$$PWD/.zig-local-cache" \
		ZIG_GLOBAL_CACHE_DIR="$$PWD/.zig-global-cache" \
		zig build -Doptimize=Debug

lorawan-host-run:
	@mkdir -p "$(OUTPUT_BASE)/lorawan-host"
	@cd "$(CURDIR)/br2-external/package/lorawan-server/src" && \
		printf '==> DB: %s\n==> Frontend: %s\n' \
			"$(OUTPUT_BASE)/lorawan-host/lorawan-server.db" \
			"$(OUTPUT_BASE)/lorawan-host/frontend" && \
		env \
			LORAWAN_SERVER_DB_PATH="$(OUTPUT_BASE)/lorawan-host/lorawan-server.db" \
			LORAWAN_SERVER_FRONTEND_PATH="$(OUTPUT_BASE)/lorawan-host/frontend" \
			ZIG_LOCAL_CACHE_DIR="$$PWD/.zig-local-cache" \
			ZIG_GLOBAL_CACHE_DIR="$$PWD/.zig-global-cache" \
			zig build run -Doptimize=Debug

%:
	@:
