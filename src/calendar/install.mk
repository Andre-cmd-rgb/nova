# The Calendar's sync (src/shell/plugins/calendar/README.md): nova-calendar-sync
# keeps iCloud, Google and CalDAV calendars, and iCal subscriptions, in step
# with the files the shell reads. Rust (this crate, built by the root cargo
# workspace), HTTP and TLS through libcurl. It runs only while it syncs
# (every five minutes, with an account), never in the background. google.json is
# the OAuth client Google sign-in uses, empty until one is registered (the
# calendar's README says how). Tests live in tests/ (cargo test: a CalDAV server
# of their own, and a secret-tool stub, a shell script, that is linted here) and
# in each module.

CALENDAR_SRC := src/calendar

SHELL_SOURCES += $(CALENDAR_SRC)/tests/support/secret-tool

INSTALL_TARGETS += install-calendar

.PHONY: install-calendar
install-calendar:
	install -Dm755 $(or $(CARGO_TARGET_DIR),target)/release/nova-calendar-sync $(DESTDIR)$(NOVA_BIN)/nova-calendar-sync
	install -Dm644 $(CALENDAR_SRC)/google.json $(DESTDIR)$(NOVA_SHARE)/calendar/google.json
