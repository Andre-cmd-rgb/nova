# nova-shell: the Quickshell desktop and the greeter entry point, run from
# $NOVA_PATH/shell. Plugin helper scripts keep their executable bit, and the
# ones people run are linked into the nova CLI: nova battery, nova screentime,
# nova mobile-data. The plugins' manifests are also collected into
# plugins/index.json, the one file the shell reads to find its plugins.

INSTALL_TARGETS += install-shell
QML_DIRS        += src/shell
SHELL_SOURCES   += $(shell find src/shell -name '*.sh' -o -path '*/plugins/*/bin/*' -type f)
TEST_SCRIPTS    += src/shell/plugins/batterylife/test/roundtrip.sh

# CLI name, then the plugin directory and script it runs
SHELL_CLI := battery:batterylife/bin/batterylife screentime:screentime/bin/screentime \
	mobile-data:mobile-data/bin/mobile-data

SHELL_DATA := $(shell cd src/shell && find . -type f \( -name '*.qml' -o -name '*.js' -o -name qmldir -o -name '*.json' \))
SHELL_EXEC := $(shell cd src/shell && find . -type f \( -name '*.sh' -o -path './plugins/*/bin/*' \) ! -path '*/test/*')

.PHONY: install-shell
install-shell:
	cd src/shell && for f in $(SHELL_DATA); do install -Dm644 "$$f" "$(DESTDIR)$(NOVA_SHARE)/shell/$$f"; done
	cd src/shell && for f in $(SHELL_EXEC); do install -Dm755 "$$f" "$(DESTDIR)$(NOVA_SHARE)/shell/$$f"; done
	tools/plugin-index src/shell/plugins >"$(DESTDIR)$(NOVA_SHARE)/shell/plugins/index.json.new"
	mv "$(DESTDIR)$(NOVA_SHARE)/shell/plugins/index.json.new" "$(DESTDIR)$(NOVA_SHARE)/shell/plugins/index.json"
	install -d $(DESTDIR)$(NOVA_BIN)
	for link in $(SHELL_CLI); do \
	  ln -sfn "../../../share/nova/shell/plugins/$${link#*:}" "$(DESTDIR)$(NOVA_BIN)/nova-$${link%%:*}"; \
	done
