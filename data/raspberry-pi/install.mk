# The Raspberry Pi's own pieces, aarch64 only: its firmware boots the kernel
# straight from the FAT partition at /boot, which nova-boot-check guards, as
# data/boot's does Limine's on x86; its initramfs; and nova-first-boot, which
# sets up a Pi from Nova's image with the questions nova-install asks
# (installer/setup.bash). image/ is what tools/build-pi-image puts in the
# image besides. Tests live in tests/unit/raspberry-pi.

RPI_SRC := data/raspberry-pi

ifeq ($(NOVA_ARCH),aarch64)
INSTALL_TARGETS += install-raspberry-pi
endif
SHELL_SOURCES   += $(wildcard $(RPI_SRC)/bin/*)

.PHONY: install-raspberry-pi
install-raspberry-pi:
	install -Dm755 -t $(DESTDIR)$(NOVA_BIN) $(RPI_SRC)/bin/*
	install -Dm644 -t $(DESTDIR)$(PREFIX)/share/libalpm/hooks $(RPI_SRC)/hooks/*.hook
	install -Dm644 $(RPI_SRC)/mkinitcpio/10-nova.conf $(DESTDIR)$(SYSCONFDIR)/mkinitcpio.conf.d/10-nova.conf
	install -Dm644 -t $(DESTDIR)$(SYSTEMD_SYSTEM) $(RPI_SRC)/systemd/nova-first-boot.service
	install -Dm644 -t $(DESTDIR)$(SYSTEMD_SYSTEM)/greetd.service.d $(RPI_SRC)/systemd/greetd.service.d/*.conf
	install -Dm644 -t $(DESTDIR)$(PREFIX)/lib/systemd/system-preset $(RPI_SRC)/systemd/10-nova.preset
	install -Dm644 installer/setup.bash $(DESTDIR)$(NOVA_SHARE)/setup.bash
