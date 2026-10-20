# Nova build entry point. `make DESTDIR=... install` is the only way files reach a
# system; the nova PKGBUILD runs exactly that. Each component contributes an
# install.mk that appends to INSTALL_TARGETS, SHELL_SOURCES, TEST_DIRS and
# TEST_SCRIPTS (standalone test programs that exit non-zero on failure).

PREFIX   ?= /usr
DESTDIR  ?=
SYSCONFDIR ?= /etc
NOVA_SHARE := $(PREFIX)/share/nova
NOVA_LIB   := $(PREFIX)/lib/nova
NOVA_BIN   := $(NOVA_LIB)/bin
SYSTEMD_SYSTEM := $(PREFIX)/lib/systemd/system
SYSTEMD_USER   := $(PREFIX)/lib/systemd/user

INSTALL_TARGETS :=
SHELL_SOURCES   :=
QML_DIRS        :=
TEST_DIRS       := tests/unit
TEST_SCRIPTS    := src/power/test/roundtrip.sh src/shell/plugins/batterylife/test/roundtrip.sh

include $(sort $(wildcard */install.mk */*/install.mk))

.PHONY: all install lint lint-shell lint-lua lint-qml lint-workflows check-names test
all:
	@echo "Nothing to build here; see packaging/ for packages. Targets: install lint test"

install: $(INSTALL_TARGETS)

lint: lint-shell lint-lua lint-qml lint-workflows check-names

lint-shell:
	shellcheck -x -S warning $(SHELL_SOURCES)

# The Hyprland configs: a syntax error there leaves the session, or the greeter,
# without its config.
lint-lua:
	git ls-files -z '*.lua' | xargs -0 -r luac -p

# Errors fail the lint; the warnings (mostly qs.* imports qmllint cannot resolve)
# are printed only when it fails, next to the error.
lint-qml:
	@set -e; log=$$(mktemp); trap 'rm -f "$$log"' EXIT; \
	for d in $(QML_DIRS); do \
	  find $$d -name '*.qml' -print0 | \
	    xargs -0 -r /usr/lib/qt6/bin/qmllint --max-warnings -1 >"$$log" 2>&1 || { cat "$$log" >&2; exit 1; }; \
	done

lint-workflows:
	actionlint

# "omarchy" belongs in NOTICE and docs/ only (docs/ARCHITECTURE.md, Naming).
check-names:
	@if grep -rnE 'omarchy[-_]|/omarchy|OMARCHY_PATH|qs\.Omarchy' src data; then \
	  echo "Omarchy names in src/ or data/, listed above" >&2; exit 1; \
	fi

test:
	bats --recursive $(TEST_DIRS)
	@set -e; for t in $(TEST_SCRIPTS); do echo "$$t"; bash "$$t" >/dev/null; done
