################################################################################
# lorawan-server
################################################################################

LORAWAN_SERVER_VERSION = 0.1.0
LORAWAN_SERVER_SITE = $(BR2_EXTERNAL_BUMBLEBEE_RPI_PATH)/package/lorawan-server/src
LORAWAN_SERVER_SITE_METHOD = local
LORAWAN_SERVER_DEPENDENCIES = sqlite

ifeq ($(BR2_aarch64),y)
LORAWAN_SERVER_ZIG_ARCH = aarch64
else ifeq ($(BR2_arm),y)
LORAWAN_SERVER_ZIG_ARCH = arm
else ifeq ($(BR2_x86_64),y)
LORAWAN_SERVER_ZIG_ARCH = x86_64
else
$(error lorawan-server: unsupported Buildroot architecture, extend LORAWAN_SERVER_ZIG_ARCH mapping)
endif

ifeq ($(BR2_TOOLCHAIN_USES_MUSL),y)
LORAWAN_SERVER_ZIG_LIBC = musl
else ifeq ($(BR2_TOOLCHAIN_USES_GLIBC),y)
LORAWAN_SERVER_ZIG_LIBC = gnu
else
$(error lorawan-server: unsupported C library for Zig target mapping)
endif

ifeq ($(BR2_arm)$(BR2_ARM_EABIHF),yy)
LORAWAN_SERVER_ZIG_ABI = eabihf
else
LORAWAN_SERVER_ZIG_ABI =
endif

LORAWAN_SERVER_ZIG_TARGET = $(LORAWAN_SERVER_ZIG_ARCH)-linux-$(LORAWAN_SERVER_ZIG_LIBC)$(LORAWAN_SERVER_ZIG_ABI)

define LORAWAN_SERVER_BUILD_CMDS
	if ! command -v zig >/dev/null 2>&1; then \
		echo "lorawan-server requires 'zig' on the build host PATH"; \
		exit 1; \
	fi
	cd $(@D) && \
		mkdir -p .zig-local-cache .zig-global-cache && \
		ZIG_LOCAL_CACHE_DIR=$(@D)/.zig-local-cache \
		ZIG_GLOBAL_CACHE_DIR=$(@D)/.zig-global-cache \
		zig build \
			-Dtarget="$(LORAWAN_SERVER_ZIG_TARGET)" \
			-Dsysroot="$(STAGING_DIR)" \
			-Doptimize=ReleaseSafe
endef

define LORAWAN_SERVER_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/zig-out/bin/lorawan-server \
		$(TARGET_DIR)/usr/bin/lorawan-server
endef

define LORAWAN_SERVER_INSTALL_INIT_SYSV
	$(INSTALL) -D -m 0755 $(LORAWAN_SERVER_PKGDIR)/S50lorawan-server \
		$(TARGET_DIR)/etc/init.d/S50lorawan-server
endef

$(eval $(generic-package))
