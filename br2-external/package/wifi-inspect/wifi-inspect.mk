################################################################################
#
# wifi-inspect
#
################################################################################

WIFI_INSPECT_VERSION = 1.0
WIFI_INSPECT_SITE = $(BR2_EXTERNAL_BUMBLEBEE_RPI_PATH)/package/wifi-inspect/src
WIFI_INSPECT_SITE_METHOD = local
WIFI_INSPECT_LICENSE = MIT
WIFI_INSPECT_LICENSE_FILES =

define WIFI_INSPECT_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(WIFI_INSPECT_SITE)/wifi-inspect.sh $(TARGET_DIR)/usr/bin/wifi-inspect
endef

$(eval $(generic-package))
