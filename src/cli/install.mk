# The `nova` dispatcher and the helpers it runs.

INSTALL_TARGETS += install-cli
SHELL_SOURCES   += src/cli/nova $(wildcard src/cli/bin/*)

.PHONY: install-cli
install-cli:
	install -Dm755 src/cli/nova $(DESTDIR)$(PREFIX)/bin/nova
	install -Dm755 -t $(DESTDIR)$(NOVA_BIN) src/cli/bin/*
