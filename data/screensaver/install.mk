# nova screensaver: ttfx's text effects in a terminal on each display. The
# shell's idle service starts it (src/shell/plugins/services/idle); its window
# rule is in data/hypr/apps/system.lua. Tests live in tests/unit/screensaver.

INSTALL_TARGETS += install-screensaver
SHELL_SOURCES   += data/screensaver/nova-screensaver data/screensaver/nova-screensaver-run

.PHONY: install-screensaver
install-screensaver:
	install -Dm755 data/screensaver/nova-screensaver $(DESTDIR)$(NOVA_BIN)/nova-screensaver
	install -Dm755 data/screensaver/nova-screensaver-run $(DESTDIR)$(NOVA_BIN)/nova-screensaver-run
	install -Dm644 data/screensaver/foot.ini $(DESTDIR)$(NOVA_SHARE)/screensaver/foot.ini
