# The installer runs on the USB stick, not on the installed system, so the nova
# package does not ship it; the ISO profile copies it and its data onto the
# stick. It is listed here so `make lint` covers it.

SHELL_SOURCES += installer/nova-install
