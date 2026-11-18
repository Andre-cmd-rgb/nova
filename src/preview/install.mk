# Quick Look (docs/using.md): Space on a file in Files. The window is the
# shell's (src/shell/plugins/preview); nova-previewer is what answers Files
# on D-Bus, under the name GNOME Sushi had, and the service file has D-Bus
# start it on the first Space. Python, as src/iphone: python-gobject is
# Nova's already. The package conflicts with sushi, which owns the same
# name and the same service file. Tests live in tests/unit/preview.

PREVIEW_SRC := src/preview

INSTALL_TARGETS += install-preview

.PHONY: install-preview
install-preview:
	install -Dm755 $(PREVIEW_SRC)/nova-previewer $(DESTDIR)$(NOVA_LIB)/nova-previewer
	install -Dm644 $(PREVIEW_SRC)/org.gnome.NautilusPreviewer.service $(DESTDIR)$(PREFIX)/share/dbus-1/services/org.gnome.NautilusPreviewer.service
