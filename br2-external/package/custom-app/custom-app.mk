################################################################################
# custom-app
################################################################################

CUSTOM_APP_VERSION = 1.0.0
CUSTOM_APP_SITE = $(BR2_EXTERNAL_BUMBLEBEE_RPI_PATH)/package/custom-app/src
CUSTOM_APP_SITE_METHOD = local


define CUSTOM_APP_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(CUSTOM_APP_SITE)/custom-app.sh $(TARGET_DIR)/usr/bin/custom-app
endef

$(eval $(generic-package))
