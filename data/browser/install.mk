# Chrome's toolbar follows the theme: a root path unit turns the color the
# theme engine mirrors (as the user) into Chrome's managed policy. Tests live
# in tests/unit/browser.

INSTALL_TARGETS += install-browser
SHELL_SOURCES   += data/browser/nova-browser-theme

.PHONY: install-browser
install-browser:
	install -Dm755 data/browser/nova-browser-theme $(DESTDIR)$(NOVA_LIB)/nova-browser-theme
	install -Dm644 -t $(DESTDIR)$(SYSTEMD_SYSTEM) data/browser/nova-browser-theme.path data/browser/nova-browser-theme.service
	install -d -m755 $(DESTDIR)$(SYSCONFDIR)/opt/chrome/policies/managed $(DESTDIR)$(SYSCONFDIR)/chromium/policies/managed
	install -d $(DESTDIR)$(SYSTEMD_SYSTEM)/paths.target.wants $(DESTDIR)$(SYSTEMD_SYSTEM)/multi-user.target.wants
	ln -sf ../nova-browser-theme.path $(DESTDIR)$(SYSTEMD_SYSTEM)/paths.target.wants/nova-browser-theme.path
	ln -sf ../nova-browser-theme.service $(DESTDIR)$(SYSTEMD_SYSTEM)/multi-user.target.wants/nova-browser-theme.service
