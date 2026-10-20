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
TEST_SCRIPTS    :=

include $(sort $(wildcard */install.mk */*/install.mk))

.PHONY: all install lint lint-shell lint-qml test
all:
	@echo "Nothing to build here; see packaging/ for packages. Targets: install lint test"

install: $(INSTALL_TARGETS)

lint: lint-shell lint-qml

lint-shell:
	shellcheck -x -S warning $(SHELL_SOURCES)

lint-qml:
	@set -e; for d in $(QML_DIRS); do \
	  find $$d -name '*.qml' -print0 | xargs -0 -r /usr/lib/qt6/bin/qmllint --max-warnings -1 >/dev/null; \
	done

test:
	bats --recursive $(TEST_DIRS)
	@set -e; for t in $(TEST_SCRIPTS); do echo "$$t"; bash "$$t" >/dev/null; done
