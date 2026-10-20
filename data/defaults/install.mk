# Defaults the shell reads from $NOVA_PATH/default; users override them in
# ~/.config/nova.

INSTALL_TARGETS += install-defaults

.PHONY: install-defaults
install-defaults:
	install -Dm644 -t $(DESTDIR)$(NOVA_SHARE)/default data/defaults/*.json*
