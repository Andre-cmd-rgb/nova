# The new user's starting files. nova-install creates the account with
# `useradd -k /usr/share/nova/skel`; nothing copies them again, so these are the
# user's from then on.

INSTALL_TARGETS += install-skel

.PHONY: install-skel
install-skel:
	cd data/skel && find . -type f ! -name install.mk -print | while IFS= read -r f; do \
	  install -Dm644 "$$f" "$(DESTDIR)$(NOVA_SHARE)/skel/$${f#./}"; \
	done
