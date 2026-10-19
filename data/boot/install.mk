# Boot chain: initramfs, Limine, snapper and the fallback guard.
# Tests live in tests/unit/installer (registered by installer/install.mk).

BOOT_SRC     := data/boot
BOOT_HOOKS   := $(PREFIX)/share/libalpm/hooks

INSTALL_TARGETS += install-boot
SHELL_SOURCES   += $(BOOT_SRC)/bin/nova-boot-check $(BOOT_SRC)/bin/nova-recovery

.PHONY: install-boot
install-boot:
	install -Dm644 $(BOOT_SRC)/mkinitcpio/10-nova.conf $(DESTDIR)$(SYSCONFDIR)/mkinitcpio.conf.d/10-nova.conf
	install -Dm644 $(BOOT_SRC)/limine/10-nova.conf $(DESTDIR)$(SYSCONFDIR)/limine-entry-tool.d/10-nova.conf
	install -Dm644 $(BOOT_SRC)/limine/limine.conf $(DESTDIR)$(NOVA_SHARE)/boot/limine.conf
	install -Dm644 $(BOOT_SRC)/snapper/root $(DESTDIR)$(SYSCONFDIR)/snapper/configs/root
	install -Dm644 $(BOOT_SRC)/snapper/snapper-conf.d $(DESTDIR)$(SYSCONFDIR)/conf.d/snapper
	install -Dm644 $(BOOT_SRC)/hooks/00-nova-boot-check-pre.hook $(DESTDIR)$(BOOT_HOOKS)/00-nova-boot-check-pre.hook
	install -Dm644 $(BOOT_SRC)/hooks/95-nova-boot-check-post.hook $(DESTDIR)$(BOOT_HOOKS)/95-nova-boot-check-post.hook
	install -Dm755 $(BOOT_SRC)/bin/nova-boot-check $(DESTDIR)$(NOVA_BIN)/nova-boot-check
	install -Dm755 $(BOOT_SRC)/bin/nova-recovery $(DESTDIR)$(NOVA_BIN)/nova-recovery
