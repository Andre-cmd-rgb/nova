# The battery charge limit: `nova battery limit` asks nova-battery-limit-apply,
# through pkexec, to write it; a udev rule and a oneshot unit put it back when a
# battery appears. Tests live in tests/unit/battery.

INSTALL_TARGETS += install-battery
SHELL_SOURCES   += data/battery/nova-battery-limit data/battery/nova-battery-limit-apply

.PHONY: install-battery
install-battery:
	install -Dm755 data/battery/nova-battery-limit $(DESTDIR)$(NOVA_BIN)/nova-battery-limit
	install -Dm755 data/battery/nova-battery-limit-apply $(DESTDIR)$(NOVA_LIB)/nova-battery-limit-apply
	install -Dm644 data/battery/org.nova.battery-limit.policy $(DESTDIR)$(PREFIX)/share/polkit-1/actions/org.nova.battery-limit.policy
	install -Dm644 data/battery/nova-battery-limit.service $(DESTDIR)$(SYSTEMD_SYSTEM)/nova-battery-limit.service
	install -Dm644 data/battery/90-nova-battery-limit.rules $(DESTDIR)$(PREFIX)/lib/udev/rules.d/90-nova-battery-limit.rules
