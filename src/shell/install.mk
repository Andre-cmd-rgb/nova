# nova-shell: the Quickshell desktop and the greeter entry point, run from
# $NOVA_PATH/shell. Plugin helper scripts keep their executable bit.

INSTALL_TARGETS += install-shell
QML_DIRS        += src/shell
SHELL_SOURCES   += $(shell find src/shell -name '*.sh' -o -path '*/plugins/*/bin/*' -type f)

SHELL_DATA := $(shell cd src/shell && find . -type f \( -name '*.qml' -o -name '*.js' -o -name qmldir -o -name '*.json' \))
SHELL_EXEC := $(shell cd src/shell && find . -type f \( -name '*.sh' -o -path './plugins/*/bin/*' \) ! -path '*/test/*')

.PHONY: install-shell
install-shell:
	cd src/shell && for f in $(SHELL_DATA); do install -Dm644 "$$f" "$(DESTDIR)$(NOVA_SHARE)/shell/$$f"; done
	cd src/shell && for f in $(SHELL_EXEC); do install -Dm755 "$$f" "$(DESTDIR)$(NOVA_SHARE)/shell/$$f"; done
