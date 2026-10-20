# Defaults the shell reads from $NOVA_PATH/default; users override them in
# ~/.config/nova. launcher.hides lists the desktop ids the app launcher leaves
# out: helper entries that come with packages Nova installs.

INSTALL_TARGETS += install-defaults

.PHONY: install-defaults
install-defaults:
	install -Dm644 -t $(DESTDIR)$(NOVA_SHARE)/default data/defaults/*.json*
	install -Dm644 -t $(DESTDIR)$(NOVA_SHARE)/default data/defaults/launcher.hides
