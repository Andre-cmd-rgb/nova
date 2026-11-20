# nova-sessiond: what the session watches for as long as it runs, in one
# small process (src/session/daemon, built by the root cargo workspace): the
# apps that keep the screen awake (org.freedesktop.ScreenSaver), the lock
# before sleep, "… quit unexpectedly" for an app a crash took away, the
# clamshell passes as displays come and go, removable drives mounted while
# somebody has unlocked, and printing: the job viewer while jobs are queued
# and the notice of a printer plugged in. Enabled for every user: each is
# part of the session, not something to turn on.

SESSIOND_SRC := src/session

INSTALL_TARGETS += install-sessiond

.PHONY: install-sessiond
install-sessiond:
	install -Dm755 $(or $(CARGO_TARGET_DIR),target)/release/nova-sessiond $(DESTDIR)$(NOVA_LIB)/nova-sessiond
	install -Dm644 $(SESSIOND_SRC)/systemd/nova-sessiond.service $(DESTDIR)$(SYSTEMD_USER)/nova-sessiond.service
	install -d $(DESTDIR)$(SYSTEMD_USER)/graphical-session.target.wants
	ln -sf ../nova-sessiond.service $(DESTDIR)$(SYSTEMD_USER)/graphical-session.target.wants/nova-sessiond.service
