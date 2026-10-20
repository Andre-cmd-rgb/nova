# Login and session: greetd, the greeter, PAM, the lock guard and the keyring.
# greetd owns /etc/greetd/config.toml, so Nova ships it as a template that
# nova-install renders with the account it creates.

SESSION_SRC := data/session

INSTALL_TARGETS += install-session
SHELL_SOURCES   += $(SESSION_SRC)/bin/nova-session-guard $(SESSION_SRC)/bin/nova-session-first-unlock \
                   $(SESSION_SRC)/bin/nova-greeter-session

.PHONY: install-session
install-session:
	install -Dm755 -t $(DESTDIR)$(NOVA_BIN) $(SESSION_SRC)/bin/*
	install -Dm644 -t $(DESTDIR)$(SYSCONFDIR)/pam.d $(SESSION_SRC)/pam.d/*
	install -Dm644 -t $(DESTDIR)$(SYSTEMD_USER) $(SESSION_SRC)/systemd/*
	install -Dm644 $(SESSION_SRC)/uwsm/10-nova $(DESTDIR)$(PREFIX)/share/uwsm/env.d/10-nova
	install -Dm644 $(SESSION_SRC)/greetd/config.toml $(DESTDIR)$(NOVA_SHARE)/session/greetd.toml
	install -Dm644 $(SESSION_SRC)/greeter/greeter-hyprland.lua $(DESTDIR)$(NOVA_SHARE)/greeter/hyprland.lua
	# Enabled for every user: the guard is what keeps autologin safe, so it is
	# not something a user can forget to turn on.
	install -d $(DESTDIR)$(SYSTEMD_USER)/graphical-session.target.wants $(DESTDIR)$(SYSTEMD_USER)/nova-unlocked.target.wants
	ln -sf ../nova-session-guard.service $(DESTDIR)$(SYSTEMD_USER)/graphical-session.target.wants/nova-session-guard.service
	ln -sf ../nova-keyring-migrate.service $(DESTDIR)$(SYSTEMD_USER)/nova-unlocked.target.wants/nova-keyring-migrate.service
