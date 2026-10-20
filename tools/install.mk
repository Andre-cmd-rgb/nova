# Maintainer tools: release pinning, the signed repository, the keyring, the ISO
# and the offscreen check of the shell's windows. They run in CI and on the
# maintainer's machine, never on an installed system, so nothing here is
# installed.

SHELL_SOURCES += $(filter-out tools/install.mk tools/render-wordmark,$(wildcard tools/*))
