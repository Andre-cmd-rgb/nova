# Quick Look (docs/using.md): Space on a file in Files. The window is the
# shell's (src/shell/plugins/preview); nova-previewer is what answers Files
# on D-Bus, under the name GNOME Sushi had, and the service file has D-Bus
# start it on the first Space. Rust, with D-Bus from the system's libsystemd
# through nova-sd and what a file is from its GIO; it is built by the root
# cargo workspace. The package conflicts with sushi, which owns the same
# name and the same service file. Tests live in tests/unit/preview and in
# the crate (cargo test).

PREVIEW_SRC := src/preview

INSTALL_TARGETS += install-preview

.PHONY: install-preview
install-preview:
	install -Dm755 $(or $(CARGO_TARGET_DIR),target)/release/nova-previewer $(DESTDIR)$(NOVA_LIB)/nova-previewer
	install -Dm644 $(PREVIEW_SRC)/org.gnome.NautilusPreviewer.service $(DESTDIR)$(PREFIX)/share/dbus-1/services/org.gnome.NautilusPreviewer.service
