# The App Store (docs/apps.md): the window is the shell's (plugins/store),
# and these are what it stands on, which `nova apps` runs too.
# nova-apps-catalog makes the list of apps from the AppStream catalogs on
# this computer (Arch's from archlinux-appstream-data, Flathub's from
# flatpak); it is built by the root cargo workspace. The helpers search it,
# say what is installed, and install and remove, as user services
# (nova-apps-run, nova-apps-job); nova-apps-apply is the root half of an
# install from Arch's repositories, through pkexec. featured is the front
# page, chosen by hand; flathub.flatpakrepo adds Flathub with its key, from
# this package rather than from the network. nova-app-store.desktop puts the
# store in the launcher, and opens Flathub's appstream:// links.

APPS_SRC := src/apps

INSTALL_TARGETS += install-apps
SHELL_SOURCES   += $(wildcard $(APPS_SRC)/bin/*)

.PHONY: install-apps
install-apps:
	install -Dm755 $(or $(CARGO_TARGET_DIR),target)/release/nova-apps-catalog $(DESTDIR)$(NOVA_BIN)/nova-apps-catalog
	install -Dm755 -t $(DESTDIR)$(NOVA_BIN) $(filter-out %/nova-apps-common %/nova-apps-apply,$(wildcard $(APPS_SRC)/bin/*))
	install -Dm644 $(APPS_SRC)/bin/nova-apps-common $(DESTDIR)$(NOVA_BIN)/nova-apps-common
	install -Dm755 $(APPS_SRC)/bin/nova-apps-apply $(DESTDIR)$(NOVA_LIB)/nova-apps-apply
	install -Dm644 $(APPS_SRC)/polkit/org.nova.apps.policy $(DESTDIR)$(PREFIX)/share/polkit-1/actions/org.nova.apps.policy
	install -Dm644 $(APPS_SRC)/data/featured $(DESTDIR)$(NOVA_SHARE)/apps/featured
	install -Dm644 $(APPS_SRC)/data/flathub.flatpakrepo $(DESTDIR)$(NOVA_SHARE)/apps/flathub.flatpakrepo
	install -Dm644 $(APPS_SRC)/data/nova-app-store.desktop $(DESTDIR)$(PREFIX)/share/applications/nova-app-store.desktop
	install -Dm644 $(APPS_SRC)/data/nova-app-store.svg $(DESTDIR)$(PREFIX)/share/icons/hicolor/scalable/apps/nova-app-store.svg
