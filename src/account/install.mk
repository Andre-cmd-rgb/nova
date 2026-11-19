# The account's password and its keyring. nova-password-change is Settings'
# Change Password: it answers passwd's prompts on a terminal of its own, so
# that pwquality and the login keyring take part. nova-keyring-migrate moves
# a keyring stored without a password into the login keyring, at the unlock
# after nova doctor's fix (nova-keyring-migrate.service, in data/session).
# Rust, built by the root cargo workspace; the Secret Service is reached
# through nova-sd. Tests live in tests/unit/session (password-change.bats,
# keyring-migrate.bats) and in the crate (cargo test).

INSTALL_TARGETS += install-account

.PHONY: install-account
install-account:
	install -Dm755 -t $(DESTDIR)$(NOVA_BIN) \
	  $(or $(CARGO_TARGET_DIR),target)/release/nova-password-change \
	  $(or $(CARGO_TARGET_DIR),target)/release/nova-keyring-migrate
