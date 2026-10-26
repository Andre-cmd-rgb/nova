# Hardware profiles: per-model data, chosen at run time by DMI (nova-hw-detect).
# A profile's etc/ tree is copied into /etc by nova-hw-apply from a pacman hook,
# because modprobe and NetworkManager drop-ins cannot apply to one model from
# /usr. The session half (uwsm env.d) checks the model itself.

HARDWARE_SRC := data/hardware

INSTALL_TARGETS += install-hardware
SHELL_SOURCES   += $(wildcard $(HARDWARE_SRC)/bin/*)

.PHONY: install-hardware
install-hardware:
	install -Dm755 -t $(DESTDIR)$(NOVA_BIN) $(HARDWARE_SRC)/bin/*
	install -Dm644 $(HARDWARE_SRC)/models $(DESTDIR)$(NOVA_SHARE)/hardware/models
	install -Dm644 $(HARDWARE_SRC)/ddc-reversed $(DESTDIR)$(NOVA_SHARE)/hardware/ddc-reversed
	cd $(HARDWARE_SRC) && for f in $$(find */ -type f ! -path 'bin/*' ! -path 'hooks/*' ! -path 'uwsm/*'); do \
	  install -Dm644 "$$f" "$(DESTDIR)$(NOVA_SHARE)/hardware/$$f"; \
	done
	install -Dm644 -t $(DESTDIR)$(PREFIX)/share/libalpm/hooks $(HARDWARE_SRC)/hooks/*.hook
	install -Dm644 -t $(DESTDIR)$(PREFIX)/share/uwsm/env.d $(HARDWARE_SRC)/uwsm/*
