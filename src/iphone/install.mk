# iPhone notifications (docs/iphone.md): nova-iphone-notifications takes an
# iPhone's notifications over Bluetooth LE, through Apple's Notification
# Center Service, and shows them as Nova's; it is a user service, enabled by
# `nova notification iphone on` for that user alone, and nobody's by default.
# Rust (daemon/), with D-Bus from the system's libsystemd through nova-sd; it
# is built by the root cargo workspace. Tests live in tests/unit/iphone and
# in the crate (cargo test).

IPHONE_SRC := src/iphone

INSTALL_TARGETS += install-iphone
SHELL_SOURCES   += $(IPHONE_SRC)/bin/nova-notification-iphone

.PHONY: install-iphone
install-iphone:
	install -Dm755 $(or $(CARGO_TARGET_DIR),target)/release/nova-iphone-notifications $(DESTDIR)$(NOVA_LIB)/nova-iphone-notifications
	install -Dm755 $(IPHONE_SRC)/bin/nova-notification-iphone $(DESTDIR)$(NOVA_BIN)/nova-notification-iphone
	install -Dm644 $(IPHONE_SRC)/nova-iphone-notifications.service $(DESTDIR)$(SYSTEMD_USER)/nova-iphone-notifications.service
