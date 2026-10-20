# The installer runs on the USB stick, not on the installed system, so the nova
# package does not ship it: tools/build-iso puts it, its data and the iso/
# profile onto the stick. It is listed here so `make lint` covers it.

SHELL_SOURCES += installer/nova-install installer/iso/profiledef.sh \
	installer/iso/airootfs/usr/local/bin/nova-install-start
