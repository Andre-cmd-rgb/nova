# Palettes, the templates every theme renders, and the wordmark background.

INSTALL_TARGETS += install-theme-data

.PHONY: install-theme-data
install-theme-data:
	install -d $(DESTDIR)$(NOVA_SHARE)/themes
	cp -r --no-preserve=mode,ownership theme/palettes/. $(DESTDIR)$(NOVA_SHARE)/themes/
	install -Dm644 -t $(DESTDIR)$(NOVA_SHARE)/templates theme/templates/*.tpl
	install -Dm644 -t $(DESTDIR)$(NOVA_SHARE)/wordmark theme/wordmark/nova.svg.tpl
