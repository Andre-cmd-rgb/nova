# Palettes, the templates every theme renders, and the wordmark: the background
# template, and as text for the setup screens and the screensaver. And Nova's
# cursor theme, made from theme/cursor's SVGs as it is installed: Hyprcursor's
# and XCursor's forms of it in /usr/share/icons/Nova (theme/cursor/build).

INSTALL_TARGETS += install-theme-data install-cursor
SHELL_SOURCES += theme/cursor/build
# Its programs are asked for before anything is installed: without them make
# install stopped only after everything else was in place.
INSTALL_TARGETS := install-cursor-tools $(INSTALL_TARGETS)

.PHONY: install-theme-data install-cursor install-cursor-tools
install-cursor-tools:
	theme/cursor/build --tools

install-theme-data:
	install -d $(DESTDIR)$(NOVA_SHARE)/themes
	cp -r --no-preserve=mode,ownership theme/palettes/. $(DESTDIR)$(NOVA_SHARE)/themes/
	install -Dm644 -t $(DESTDIR)$(NOVA_SHARE)/templates theme/templates/*.tpl
	install -Dm644 -t $(DESTDIR)$(NOVA_SHARE)/wordmark theme/wordmark/nova.svg.tpl theme/wordmark/nova.txt

install-cursor:
	theme/cursor/build $(DESTDIR)$(PREFIX)/share/icons/Nova
