# The installer runs on the USB stick, not on the installed system, so the nova
# package does not ship it: tools/build-iso puts it, its data and the iso/
# profile onto the stick. It is listed here so `make lint` covers it.
#
# nova-usb, which makes the stick, does ship (`nova usb`), with ui.bash, the
# look of its screens, and is also on every release page for making a stick
# from another system (with ui.bash written in: tools/inline-ui).

INSTALL_TARGETS += install-usb
SHELL_SOURCES += installer/nova-install installer/nova-usb installer/ui.bash installer/wifi.bash installer/iso/profiledef.sh \
	installer/iso/airootfs/usr/local/bin/nova-install-start

.PHONY: install-usb
install-usb:
	install -Dm755 installer/nova-usb $(DESTDIR)$(NOVA_BIN)/nova-usb
	install -Dm644 installer/ui.bash $(DESTDIR)$(NOVA_SHARE)/ui.bash
