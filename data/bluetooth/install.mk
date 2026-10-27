# Bluetooth LE on or off: `nova bluetooth le` asks nova-bluetooth-le-apply,
# through pkexec, to set ControllerMode in /etc/bluetooth/main.conf. Tests
# live in tests/unit/bluetooth.

INSTALL_TARGETS += install-bluetooth
SHELL_SOURCES   += data/bluetooth/nova-bluetooth-le data/bluetooth/nova-bluetooth-le-apply

.PHONY: install-bluetooth
install-bluetooth:
	install -Dm755 data/bluetooth/nova-bluetooth-le $(DESTDIR)$(NOVA_BIN)/nova-bluetooth-le
	install -Dm755 data/bluetooth/nova-bluetooth-le-apply $(DESTDIR)$(NOVA_LIB)/nova-bluetooth-le-apply
	install -Dm644 data/bluetooth/org.nova.bluetooth-le.policy $(DESTDIR)$(PREFIX)/share/polkit-1/actions/org.nova.bluetooth-le.policy
