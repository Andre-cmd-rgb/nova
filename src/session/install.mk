# nova-sessiond: what the session watches for as long as it runs, in one
# small process (src/session/daemon, built by the root cargo workspace): the
# apps that keep the screen awake (org.freedesktop.ScreenSaver), the lock
# before sleep, "… quit unexpectedly" for an app a crash took away, the
# clamshell passes as displays come and go, removable drives mounted while
# somebody has unlocked, and printing's notices. Enabled for every user: each
# is part of the session, not something to turn on.
#
# The same program is nova-pinentry, gpg-agent's questions on Nova's card,
# which Arch's /usr/bin/pinentry runs through /etc/pinentry/preexec,
# nova-share-picker, what an app may show of the screen, which
# xdg-desktop-portal-hyprland runs (~/.config/hypr/xdph.conf), and
# nova-sim-pin, the SIM's PIN to ModemManager for mobile-data, from the
# standard input rather than an argument.

SESSIOND_SRC := src/session

INSTALL_TARGETS += install-sessiond

.PHONY: install-sessiond
install-sessiond:
	install -Dm755 $(or $(CARGO_TARGET_DIR),target)/release/nova-sessiond $(DESTDIR)$(NOVA_LIB)/nova-sessiond
	install -Dm644 $(SESSIOND_SRC)/systemd/nova-sessiond.service $(DESTDIR)$(SYSTEMD_USER)/nova-sessiond.service
	install -d $(DESTDIR)$(SYSTEMD_USER)/graphical-session.target.wants
	ln -sf ../nova-sessiond.service $(DESTDIR)$(SYSTEMD_USER)/graphical-session.target.wants/nova-sessiond.service
	install -d $(DESTDIR)$(NOVA_BIN)
	ln -sf ../nova-sessiond $(DESTDIR)$(NOVA_BIN)/nova-pinentry
	ln -sf ../nova-sessiond $(DESTDIR)$(NOVA_BIN)/nova-share-picker
	ln -sf ../nova-sessiond $(DESTDIR)$(NOVA_BIN)/nova-sim-pin
	install -Dm644 $(SESSIOND_SRC)/pinentry/preexec $(DESTDIR)$(SYSCONFDIR)/pinentry/preexec
