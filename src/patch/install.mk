# Nova patches: fixes for one computer's faults, kept across reinstalls by
# export and add (docs/patches.md). nova patch is the command, and
# nova-patch-apply its root half, through pkexec; nova-patch-ram.service
# finishes a memory test at the start that runs it, and does nothing at any
# other.

PATCH_SRC := src/patch

INSTALL_TARGETS += install-patch
SHELL_SOURCES   += $(PATCH_SRC)/bin/nova-patch $(PATCH_SRC)/bin/nova-patch-apply

.PHONY: install-patch
install-patch:
	install -Dm755 $(PATCH_SRC)/bin/nova-patch $(DESTDIR)$(NOVA_BIN)/nova-patch
	install -Dm755 $(PATCH_SRC)/bin/nova-patch-apply $(DESTDIR)$(NOVA_LIB)/nova-patch-apply
	install -Dm644 $(PATCH_SRC)/polkit/org.nova.patch.policy $(DESTDIR)$(PREFIX)/share/polkit-1/actions/org.nova.patch.policy
	install -Dm644 $(PATCH_SRC)/systemd/nova-patch-ram.service $(DESTDIR)$(SYSTEMD_SYSTEM)/nova-patch-ram.service
	install -d $(DESTDIR)$(SYSTEMD_SYSTEM)/multi-user.target.wants
	ln -sf ../nova-patch-ram.service $(DESTDIR)$(SYSTEMD_SYSTEM)/multi-user.target.wants/nova-patch-ram.service
