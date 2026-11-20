# Firmware: what lets nova-firmware-job (src/cli) give fwupd back its memory
# when a check is over, without asking for a password.

INSTALL_TARGETS += install-firmware

.PHONY: install-firmware
install-firmware:
	install -Dm644 data/firmware/50-nova-fwupd-quit.rules $(DESTDIR)$(PREFIX)/share/polkit-1/rules.d/50-nova-fwupd-quit.rules
