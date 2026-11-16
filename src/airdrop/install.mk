# AirDrop: receiving from iPhones nearby and sending to them (docs/airdrop.md).
# nova-airdropd is the receiver and the sender, an AWDL node on the air and
# AirDrop's HTTPS on top; nova-airdrop is `nova airdrop`, which switches it,
# answers what it asks and hands it what to send;
# nova-airdrop-radio lends it the Wi-Fi card and takes it back, as root, around
# nova-airdrop@.service; nova-airdrop-apply is the root half of on and off,
# through pkexec. nova-airdrop-bell is AirDrop's doorbell, Bluetooth listening
# for the user's iPhone, in nova-airdrop-bell@.service. The three programs are
# built by the root cargo workspace. nova-airdrop.desktop puts AirDrop in
# Files' Open With for photos, videos and music: the types Nova gives an app
# of its own (data/mime/mimeapps.list), so that AirDrop is never what opens a
# file; and not in the launcher.
#
# The service is started for whoever asks and enabled for nobody: AirDrop is
# on while it is wanted, since the Wi-Fi is off the network meanwhile. The
# doorbell is enabled by `nova airdrop bell on`, for that user alone.

AIRDROP_SRC := src/airdrop

INSTALL_TARGETS += install-airdrop
SHELL_SOURCES   += $(AIRDROP_SRC)/bin/nova-airdrop-radio $(AIRDROP_SRC)/bin/nova-airdrop-apply

.PHONY: install-airdrop
install-airdrop:
	install -Dm755 $(or $(CARGO_TARGET_DIR),target)/release/nova-airdrop $(DESTDIR)$(NOVA_BIN)/nova-airdrop
	install -Dm755 $(or $(CARGO_TARGET_DIR),target)/release/nova-airdropd $(DESTDIR)$(NOVA_LIB)/nova-airdropd
	install -Dm755 $(or $(CARGO_TARGET_DIR),target)/release/nova-airdrop-bell $(DESTDIR)$(NOVA_LIB)/nova-airdrop-bell
	install -Dm755 $(AIRDROP_SRC)/bin/nova-airdrop-radio $(DESTDIR)$(NOVA_LIB)/nova-airdrop-radio
	install -Dm755 $(AIRDROP_SRC)/bin/nova-airdrop-apply $(DESTDIR)$(NOVA_LIB)/nova-airdrop-apply
	install -Dm644 $(AIRDROP_SRC)/polkit/org.nova.airdrop.policy $(DESTDIR)$(PREFIX)/share/polkit-1/actions/org.nova.airdrop.policy
	install -Dm644 $(AIRDROP_SRC)/systemd/nova-airdrop@.service $(DESTDIR)$(SYSTEMD_SYSTEM)/nova-airdrop@.service
	install -Dm644 $(AIRDROP_SRC)/systemd/nova-airdrop-bell@.service $(DESTDIR)$(SYSTEMD_SYSTEM)/nova-airdrop-bell@.service
	install -Dm644 $(AIRDROP_SRC)/systemd/nova-airdrop-bell-wake@.service $(DESTDIR)$(SYSTEMD_SYSTEM)/nova-airdrop-bell-wake@.service
	install -Dm644 $(AIRDROP_SRC)/nova-airdrop.desktop $(DESTDIR)$(PREFIX)/share/applications/nova-airdrop.desktop
