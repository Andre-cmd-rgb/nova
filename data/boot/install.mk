# Boot chain: initramfs, Limine, snapper and the fallback guard. snapper owns
# /etc/conf.d/snapper, so its config ships as a template: nova-install runs
# `snapper -c root create-config --template nova /`.
# Tests live in tests/unit/installer.

BOOT_SRC     := data/boot
BOOT_HOOKS   := $(PREFIX)/share/libalpm/hooks

INSTALL_TARGETS += install-boot
SHELL_SOURCES   += $(wildcard $(BOOT_SRC)/bin/*)

.PHONY: install-boot
install-boot:
	install -Dm644 $(BOOT_SRC)/mkinitcpio/10-nova.conf $(DESTDIR)$(SYSCONFDIR)/mkinitcpio.conf.d/10-nova.conf
	install -Dm644 $(BOOT_SRC)/limine/10-nova.conf $(DESTDIR)$(SYSCONFDIR)/limine-entry-tool.d/10-nova.conf
	install -Dm644 $(BOOT_SRC)/limine/limine.conf $(DESTDIR)$(NOVA_SHARE)/boot/limine.conf
	install -Dm644 $(BOOT_SRC)/snapper/root $(DESTDIR)$(PREFIX)/share/snapper/config-templates/nova
	install -Dm644 -t $(DESTDIR)$(BOOT_HOOKS) $(BOOT_SRC)/hooks/*.hook
	install -Dm755 -t $(DESTDIR)$(NOVA_BIN) $(BOOT_SRC)/bin/*
