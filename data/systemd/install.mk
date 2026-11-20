# systemd: the session's user units, Nova's logind and sleep policy, and the
# memory setup (zram, the reclaim sysctls, systemd-oomd). The monitor
# recovery, the speaker tuning's login check and the look for failed services
# are on for everyone (the lock before sleep and Bluetooth pairing's questions
# are nova-sessiond's, src/session); the tuning itself is enabled per machine
# by nova-audio-tuning, which that check runs. Vendor config goes in /usr/lib
# so /etc stays the administrator's.
#
# What starts at login is Nova's choice, not each package's: uwsm starts every
# entry in /etc/xdg/autostart (systemd-xdg-autostart-generator makes each an
# app-<name>@autostart.service), so the ones Nova does not want are masked here,
# over the generator's units, which rank below /usr/lib. The printer applet
# (system-config-printer) held 40 MB all day to wait for printing: its job
# viewer (a printer out of paper, a document sent, a held job's password) and
# the notice of a printer plugged in. nova-sessiond's printing duty does that
# waiting, starts the applet's job viewer only while jobs are queued, and
# tells of a new printer itself (src/session/daemon/src/printing.rs).
# limine-snapper-notify follows every error in the system log, all day,
# to tell of its own few; nova-doctor-services, run every ten minutes, says
# the errors snapper's plugin writes to the journal when a snapshot cannot
# reach the boot menu, and a failed limine-snapper-sync. The install test fails when
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
