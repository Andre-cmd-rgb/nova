# Networking: the Wi-Fi rules of the computer's country, and name resolution
# that finds printers through Avahi and answers nobody's LLMNR, and captive
# portal checks. Tests live in tests/unit/network.

NETWORK_SRC := data/network

INSTALL_TARGETS += install-network
SHELL_SOURCES   += $(NETWORK_SRC)/bin/nova-wireless-regdom $(NETWORK_SRC)/bin/nova-nsswitch-mdns

.PHONY: install-network
install-network:
	install -Dm755 -t $(DESTDIR)$(NOVA_BIN) $(NETWORK_SRC)/bin/*
	install -Dm644 -t $(DESTDIR)$(PREFIX)/share/libalpm/hooks $(NETWORK_SRC)/hooks/*.hook
	install -Dm644 $(NETWORK_SRC)/resolved/10-nova.conf $(DESTDIR)$(PREFIX)/lib/systemd/resolved.conf.d/10-nova.conf
	install -Dm644 $(NETWORK_SRC)/NetworkManager/30-nova-connectivity.conf $(DESTDIR)$(PREFIX)/lib/NetworkManager/conf.d/30-nova-connectivity.conf
