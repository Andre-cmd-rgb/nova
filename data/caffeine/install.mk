# nova caffeine: the screen stays on, and a closed lid only turns it off. The
# shell's idle service watches its switch; the Hyprland lid bindings go through
# it (data/hypr/bindings/utilities.lua); the modem write is root's, through
# pkexec. Tests live in tests/unit/caffeine.

INSTALL_TARGETS += install-caffeine
SHELL_SOURCES   += data/caffeine/nova-caffeine data/caffeine/nova-caffeine-modem

.PHONY: install-caffeine
install-caffeine:
	install -Dm755 data/caffeine/nova-caffeine $(DESTDIR)$(NOVA_BIN)/nova-caffeine
	install -Dm755 data/caffeine/nova-caffeine-modem $(DESTDIR)$(NOVA_LIB)/nova-caffeine-modem
	install -Dm644 data/caffeine/org.nova.caffeine-modem.policy $(DESTDIR)$(PREFIX)/share/polkit-1/actions/org.nova.caffeine-modem.policy
