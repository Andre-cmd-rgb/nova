# systemd: the session's user units, Nova's logind and sleep policy, and the
# memory setup (zram, the reclaim sysctls, systemd-oomd). bt-agent, the sleep
# lock and the monitor recovery are on for everyone; the speaker tuning is
# enabled per machine by nova-audio-tuning. Vendor config goes in /usr/lib so
# /etc stays the administrator's.

INSTALL_TARGETS += install-systemd

.PHONY: install-systemd
install-systemd:
	install -Dm644 -t $(DESTDIR)$(SYSTEMD_USER) data/systemd/user/*.service
	install -Dm644 -t $(DESTDIR)$(SYSTEMD_USER)/app.slice.d data/systemd/user/app.slice.d/*.conf
	install -d $(DESTDIR)$(SYSTEMD_USER)/graphical-session.target.wants $(DESTDIR)$(SYSTEMD_USER)/graphical-session-pre.target.wants
	ln -sf ../bt-agent.service $(DESTDIR)$(SYSTEMD_USER)/graphical-session.target.wants/bt-agent.service
	ln -sf ../nova-sleep-lock.service $(DESTDIR)$(SYSTEMD_USER)/graphical-session.target.wants/nova-sleep-lock.service
	ln -sf ../nova-recover-internal-monitor.service $(DESTDIR)$(SYSTEMD_USER)/graphical-session-pre.target.wants/nova-recover-internal-monitor.service
	install -Dm644 data/systemd/logind.conf.d/10-nova.conf $(DESTDIR)$(PREFIX)/lib/systemd/logind.conf.d/10-nova.conf
	install -Dm644 data/systemd/sleep.conf.d/10-nova.conf $(DESTDIR)$(PREFIX)/lib/systemd/sleep.conf.d/10-nova.conf
	install -Dm644 data/systemd/system/tpm2-setup.conf $(DESTDIR)$(SYSTEMD_SYSTEM)/systemd-tpm2-setup.service.d/10-nova.conf
	install -Dm644 data/systemd/system/tpm2-setup.conf $(DESTDIR)$(SYSTEMD_SYSTEM)/systemd-tpm2-setup-early.service.d/10-nova.conf
	install -Dm644 data/systemd/zram-generator.conf.d/10-nova.conf $(DESTDIR)$(PREFIX)/lib/systemd/zram-generator.conf.d/10-nova.conf
	install -Dm644 data/systemd/oomd.conf.d/10-nova.conf $(DESTDIR)$(PREFIX)/lib/systemd/oomd.conf.d/10-nova.conf
	install -Dm644 data/systemd/sysctl.d/90-nova.conf $(DESTDIR)$(PREFIX)/lib/sysctl.d/90-nova.conf
