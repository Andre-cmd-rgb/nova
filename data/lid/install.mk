# nova lid-awake: close the lid and keep working. The Hyprland lid bindings
# go through it (data/hypr/bindings/utilities.lua); the modem write is root's,
# through pkexec. Tests live in tests/unit/lid.

INSTALL_TARGETS += install-lid
SHELL_SOURCES   += data/lid/nova-lid-awake data/lid/nova-lid-awake-modem

.PHONY: install-lid
install-lid:
	install -Dm755 data/lid/nova-lid-awake $(DESTDIR)$(NOVA_BIN)/nova-lid-awake
	install -Dm755 data/lid/nova-lid-awake-modem $(DESTDIR)$(NOVA_LIB)/nova-lid-awake-modem
	install -Dm644 data/lid/org.nova.lid-awake-modem.policy $(DESTDIR)$(PREFIX)/share/polkit-1/actions/org.nova.lid-awake-modem.policy
