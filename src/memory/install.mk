# nova-memory-pressure (built by the root cargo workspace): the kernel's
# memory reserve is nova-memory-reserve's lean one at rest (data/systemd) and
# the full 1.25% while memory is short. On for every computer; it ends at
# once on one whose boot value is the full one.

INSTALL_TARGETS += install-memory

.PHONY: install-memory
install-memory:
	install -Dm755 $(or $(CARGO_TARGET_DIR),target)/release/nova-memory-pressure $(DESTDIR)$(NOVA_LIB)/nova-memory-pressure
	install -Dm644 src/memory/systemd/nova-memory-pressure.service $(DESTDIR)$(SYSTEMD_SYSTEM)/nova-memory-pressure.service
	install -d $(DESTDIR)$(SYSTEMD_SYSTEM)/multi-user.target.wants
	ln -sf ../nova-memory-pressure.service $(DESTDIR)$(SYSTEMD_SYSTEM)/multi-user.target.wants/nova-memory-pressure.service
