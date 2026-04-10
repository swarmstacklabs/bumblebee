################################################################################
# lorawan-server-ui
################################################################################

LORAWAN_SERVER_UI_VERSION = 0.1.0
LORAWAN_SERVER_UI_SITE = $(BR2_EXTERNAL_BUMBLEBEE_RPI_PATH)/../../bumblebee-lns/ui
LORAWAN_SERVER_UI_SITE_METHOD = local

define LORAWAN_SERVER_UI_BUILD_CMDS
	if [ ! -f "$(@D)/dist/index.html" ]; then \
		echo "lorawan-server-ui: missing built UI assets at $(@D)/dist"; \
		echo "Build the Vue app first, for example: npm --prefix $(LORAWAN_SERVER_UI_SITE) run build:prod"; \
		exit 1; \
	fi
endef

define LORAWAN_SERVER_UI_INSTALL_TARGET_CMDS
	mkdir -p $(TARGET_DIR)/usr/share/lorawan-server/frontend
	cp -a $(@D)/dist/. $(TARGET_DIR)/usr/share/lorawan-server/frontend/
endef

$(eval $(generic-package))
