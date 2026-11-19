# The Calendar's sync (src/shell/plugins/calendar/README.md): nova-calendar-sync
# keeps iCloud, Google and CalDAV calendars, and iCal subscriptions, in step
# with the files the shell reads. Python: its standard library has HTTP, TLS
# and XML, which Nova's crate-less Rust has not. It runs only while it syncs
# (every five minutes, with an account), never in the background. google.json is
# the OAuth client Google sign-in uses, empty until one is registered (the
# calendar's README says how). Tests live in tests/unit/calendar.

CALENDAR_SRC := src/calendar

INSTALL_TARGETS += install-calendar

.PHONY: install-calendar
install-calendar:
	install -Dm755 $(CALENDAR_SRC)/nova-calendar-sync $(DESTDIR)$(NOVA_BIN)/nova-calendar-sync
	install -Dm644 $(CALENDAR_SRC)/google.json $(DESTDIR)$(NOVA_SHARE)/calendar/google.json
