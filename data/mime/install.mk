# Which app opens a file nobody has picked one for: photos in Loupe, video and
# music in mpv, text in VS Code. Beside the data dirs' desktop entries, where
# every user's own choice comes first.

INSTALL_TARGETS += install-mime

.PHONY: install-mime
install-mime:
	install -Dm644 data/mime/mimeapps.list $(DESTDIR)$(PREFIX)/share/applications/mimeapps.list
