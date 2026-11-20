# systemd: the session's user units, Nova's logind and sleep policy, and the
# memory setup (zram, the reclaim sysctls, systemd-oomd). The monitor
# recovery, the speaker tuning's login check and the look for failed services
# are on for everyone (the lock before sleep is nova-sessiond's, src/session);
# bt-agent runs only while nova-bluetooth-device pairs, and the tuning itself is
# enabled per machine by nova-audio-tuning, which that check runs. Vendor config
# goes in /usr/lib so /etc stays the administrator's.
#
# What starts at login is Nova's choice, not each package's: uwsm starts every
# entry in /etc/xdg/autostart (systemd-xdg-autostart-generator makes each an
# app-<name>@autostart.service), so the ones Nova does not want are masked here,
# over the generator's units, which rank below /usr/lib. The printer applet
# (system-config-printer) is a tray icon, and Nova has no tray; it held 40 MB
# all day. limine-snapper-notify follows every error in the system log, all day,
# to tell of its own few; Nova's look for failed services says when
# limine-snapper-sync fails (nova-doctor-services). The install test fails when
# a package autostart Nova has not chosen runs (tests/install/probe).
AUTOSTART_OFF := print-applet limine-snapper-notify

INSTALL_TARGETS += install-systemd

.PHONY: install-systemd
install-systemd:
	install -Dm644 -t $(DESTDIR)$(SYSTEMD_USER) data/systemd/user/*.service data/systemd/user/*.timer
	install -Dm644 -t $(DESTDIR)$(SYSTEMD_USER)/app.slice.d data/systemd/user/app.slice.d/*.conf
	install -d $(DESTDIR)$(SYSTEMD_USER)/graphical-session.target.wants $(DESTDIR)$(SYSTEMD_USER)/graphical-session-pre.target.wants
	ln -sf ../nova-speaker-tuning-auto.service $(DESTDIR)$(SYSTEMD_USER)/graphical-session.target.wants/nova-speaker-tuning-auto.service
	ln -sf ../nova-doctor-services.timer $(DESTDIR)$(SYSTEMD_USER)/graphical-session.target.wants/nova-doctor-services.timer
	ln -sf ../nova-recover-internal-monitor.service $(DESTDIR)$(SYSTEMD_USER)/graphical-session-pre.target.wants/nova-recover-internal-monitor.service
	for name in $(AUTOSTART_OFF); do \
	  ln -sf /dev/null "$(DESTDIR)$(SYSTEMD_USER)/app-$$(printf %s "$$name" | sed 's/-/\\x2d/g')@autostart.service"; \
	done
	install -Dm644 data/systemd/logind.conf.d/10-nova.conf $(DESTDIR)$(PREFIX)/lib/systemd/logind.conf.d/10-nova.conf
	install -Dm644 data/systemd/sleep.conf.d/10-nova.conf $(DESTDIR)$(PREFIX)/lib/systemd/sleep.conf.d/10-nova.conf
	install -Dm644 data/systemd/system/tpm2-setup.conf $(DESTDIR)$(SYSTEMD_SYSTEM)/systemd-tpm2-setup.service.d/10-nova.conf
	install -Dm644 data/systemd/system/tpm2-setup.conf $(DESTDIR)$(SYSTEMD_SYSTEM)/systemd-tpm2-setup-early.service.d/10-nova.conf
	install -Dm644 data/systemd/zram-generator.conf.d/10-nova.conf $(DESTDIR)$(PREFIX)/lib/systemd/zram-generator.conf.d/10-nova.conf
	install -Dm644 data/systemd/oomd.conf.d/10-nova.conf $(DESTDIR)$(PREFIX)/lib/systemd/oomd.conf.d/10-nova.conf
	install -Dm644 data/systemd/sysctl.d/90-nova.conf $(DESTDIR)$(PREFIX)/lib/sysctl.d/90-nova.conf
	install -Dm644 data/systemd/tmpfiles.d/nova.conf $(DESTDIR)$(PREFIX)/lib/tmpfiles.d/nova.conf
	install -Dm644 data/systemd/tmpfiles.d/nova-huge-pages.conf $(DESTDIR)$(PREFIX)/lib/tmpfiles.d/nova-huge-pages.conf
