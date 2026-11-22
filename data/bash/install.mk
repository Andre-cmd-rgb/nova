# Nova's interactive bash (history, Tab, the prompt), which the account's
# ~/.bashrc from Nova's skel reads first: an update improves it in every
# account without touching the user's file.

INSTALL_TARGETS += install-bash
SHELL_SOURCES   += data/bash/bashrc

.PHONY: install-bash
install-bash:
	install -Dm644 data/bash/bashrc $(DESTDIR)$(NOVA_SHARE)/default/bash/bashrc
