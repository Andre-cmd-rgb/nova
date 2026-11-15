# nova screensaver: Nova's text effects in a terminal on each display. The
# shell's idle service starts it (src/shell/plugins/services/idle); its window
# rule is in data/hypr/rules.lua. Tests live in tests/unit/screensaver.
# nova-screensaver-effect, which plays them (src/screensaver), is built by
# `cargo build --release` at the repository root, like nova-theme.

INSTALL_TARGETS += install-screensaver
SHELL_SOURCES   += data/screensaver/nova-screensaver data/screensaver/nova-screensaver-run

.PHONY: install-screensaver
install-screensaver:
	install -Dm755 data/screensaver/nova-screensaver $(DESTDIR)$(NOVA_BIN)/nova-screensaver
	install -Dm755 data/screensaver/nova-screensaver-run $(DESTDIR)$(NOVA_BIN)/nova-screensaver-run
	install -Dm755 $(or $(CARGO_TARGET_DIR),target)/release/nova-screensaver-effect $(DESTDIR)$(NOVA_BIN)/nova-screensaver-effect
	install -Dm644 data/screensaver/foot.ini $(DESTDIR)$(NOVA_SHARE)/screensaver/foot.ini
