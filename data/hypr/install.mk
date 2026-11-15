# Hyprland defaults. Lua requires them as default.hypr.*, so they live under
# $NOVA_PATH/default/hypr.

INSTALL_TARGETS += install-hypr

HYPR_FILES := $(shell cd data/hypr && find . -name '*.lua')

.PHONY: install-hypr
install-hypr:
	cd data/hypr && for f in $(HYPR_FILES); do install -Dm644 "$$f" "$(DESTDIR)$(NOVA_SHARE)/default/hypr/$$f"; done
	install -Dm644 -t $(DESTDIR)$(PREFIX)/share/libalpm/hooks data/hypr/hooks/*.hook
