# Networking: the Wi-Fi rules of the computer's country. Tests live in
# tests/unit/network.

NETWORK_SRC := data/network

INSTALL_TARGETS += install-network
SHELL_SOURCES   += $(NETWORK_SRC)/bin/nova-wireless-regdom

.PHONY: install-network
install-network:
	install -Dm755 -t $(DESTDIR)$(NOVA_BIN) $(NETWORK_SRC)/bin/*
	install -Dm644 -t $(DESTDIR)$(PREFIX)/share/libalpm/hooks $(NETWORK_SRC)/hooks/*.hook
