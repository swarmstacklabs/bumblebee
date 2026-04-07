################################################################################
# skeleton-app
################################################################################

SKELETON_APP_VERSION = 1.0.0
SKELETON_APP_SITE = $(BR2_EXTERNAL_BUMBLEBEE_RPI_PATH)/package/skeleton-app/src
SKELETON_APP_SITE_METHOD = local

define SKELETON_APP_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(SKELETON_APP_SITE)/skeleton-app.sh $(TARGET_DIR)/usr/bin/skeleton-app
endef

$(eval $(generic-package))
