# iPhone notifications (docs/iphone.md): nova-iphone-notifications takes an
# iPhone's notifications over Bluetooth LE, through Apple's Notification
# Center Service, and shows them as Nova's; it is a user service, enabled by
# `nova notification iphone on` for that user alone, and nobody's by default.
# Python, as nova-idle-inhibitors: python-dbus and python-gobject are Nova's
# already, and Nova's Rust uses no crates, so it has no D-Bus of its own.
# Tests live in tests/unit/iphone.

IPHONE_SRC := src/iphone

INSTALL_TARGETS += install-iphone
SHELL_SOURCES   += $(IPHONE_SRC)/bin/nova-notification-iphone

.PHONY: install-iphone
install-iphone:
	install -Dm755 $(IPHONE_SRC)/nova-iphone-notifications $(DESTDIR)$(NOVA_LIB)/nova-iphone-notifications
	install -Dm755 $(IPHONE_SRC)/bin/nova-notification-iphone $(DESTDIR)$(NOVA_BIN)/nova-notification-iphone
	install -Dm644 $(IPHONE_SRC)/nova-iphone-notifications.service $(DESTDIR)$(SYSTEMD_USER)/nova-iphone-notifications.service
