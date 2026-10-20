# User units for the session. bt-agent, the sleep lock and the monitor
# recovery are on for everyone; the speaker tuning is enabled per machine by
# nova-audio-tuning.

INSTALL_TARGETS += install-systemd

.PHONY: install-systemd
install-systemd:
	install -Dm644 -t $(DESTDIR)$(SYSTEMD_USER) data/systemd/user/*.service
	install -Dm644 -t $(DESTDIR)$(SYSTEMD_USER)/app.slice.d data/systemd/user/app.slice.d/*.conf
	install -d $(DESTDIR)$(SYSTEMD_USER)/graphical-session.target.wants $(DESTDIR)$(SYSTEMD_USER)/graphical-session-pre.target.wants
	ln -sf ../bt-agent.service $(DESTDIR)$(SYSTEMD_USER)/graphical-session.target.wants/bt-agent.service
	ln -sf ../nova-sleep-lock.service $(DESTDIR)$(SYSTEMD_USER)/graphical-session.target.wants/nova-sleep-lock.service
	ln -sf ../nova-recover-internal-monitor.service $(DESTDIR)$(SYSTEMD_USER)/graphical-session-pre.target.wants/nova-recover-internal-monitor.service
