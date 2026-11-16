# Networking: the Wi-Fi rules of the computer's country, ModemManager on
# for a cellular modem with every FCC unlock it ships, and name resolution
# that finds printers through Avahi and answers nobody's LLMNR, and captive
# portal checks. Tests live in tests/unit/network.

NETWORK_SRC := data/network

INSTALL_TARGETS += install-network
SHELL_SOURCES   += $(NETWORK_SRC)/bin/nova-wireless-regdom $(NETWORK_SRC)/bin/nova-nsswitch-mdns $(NETWORK_SRC)/bin/nova-modemmanager

# A laptop's cellular modem is often locked by its maker (an FCC lock) until
# a vendor tool unlocks it, and then it cannot be turned on at all.
# ModemManager ships an unlock for the modems it knows, one script per PCI or
# USB vid:pid in fcc-unlock.available.d, and runs none it was not given: a
# distribution's go in its package directory, fcc-unlock.d, the admin's in
# /etc/ModemManager/fcc-unlock.d, which it reads first and so overrides
# these. Nova turns every one of them on, linked by name as ModemManager's
# documentation does it. The links are made from the modemmanager installed
# where the package is built (a dependency, so always there), so a new
# release of ModemManager's list is Nova's at its next build. /usr/lib is
# right for them: ModemManager's documentation gives that directory to the
# distribution, and Arch's modemmanager owns it with nothing in it. A
# maker's own script goes in /etc instead (nova doctor says so): put in
# /usr/lib under a name Nova links, it would be a pacman conflict.
MM_FCC_AVAILABLE ?= /usr/share/ModemManager/fcc-unlock.available.d
MM_FCC_TARGET    := /usr/share/ModemManager/fcc-unlock.available.d
MM_FCC_ENABLED   := $(PREFIX)/lib/ModemManager/fcc-unlock.d

.PHONY: install-network
install-network:
	install -Dm755 -t $(DESTDIR)$(NOVA_BIN) $(NETWORK_SRC)/bin/*
	install -Dm644 -t $(DESTDIR)$(PREFIX)/share/libalpm/hooks $(NETWORK_SRC)/hooks/*.hook
	install -Dm644 $(NETWORK_SRC)/resolved/10-nova.conf $(DESTDIR)$(PREFIX)/lib/systemd/resolved.conf.d/10-nova.conf
	install -Dm644 $(NETWORK_SRC)/NetworkManager/30-nova-connectivity.conf $(DESTDIR)$(PREFIX)/lib/NetworkManager/conf.d/30-nova-connectivity.conf
	install -d $(DESTDIR)$(MM_FCC_ENABLED)
	for script in $(MM_FCC_AVAILABLE)/*:*; do \
	  [ -e "$$script" ] || continue; \
	  ln -sfn "$(MM_FCC_TARGET)/$${script##*/}" "$(DESTDIR)$(MM_FCC_ENABLED)/$${script##*/}"; \
	done
