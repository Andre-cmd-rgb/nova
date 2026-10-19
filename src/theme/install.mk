# nova-theme, the theme engine. Built by `cargo build --release` at the
# repository root (the PKGBUILD's build()), so the binary is in target/.

INSTALL_TARGETS += install-theme-engine

.PHONY: install-theme-engine
install-theme-engine:
	install -Dm755 target/release/nova-theme $(DESTDIR)$(NOVA_BIN)/nova-theme
