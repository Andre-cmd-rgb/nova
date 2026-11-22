# The new user's starting files. nova-install creates the account with
# `useradd -k /usr/share/nova/skel`, and they are the user's from then on. A
# file still byte for byte as an earlier release shipped it is brought to this
# one by nova update (src/cli/bin/nova-update-home, which lists each version).

INSTALL_TARGETS += install-skel

.PHONY: install-skel
install-skel:
	cd data/skel && find . -type f ! -name install.mk -print | while IFS= read -r f; do \
	  install -Dm644 "$$f" "$(DESTDIR)$(NOVA_SHARE)/skel/$${f#./}"; \
	done
