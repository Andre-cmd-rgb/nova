# Maintainer tools: release pinning, the signed repository, the keyring, the ISO,
# the shell's plugin index and the offscreen check of its windows. They run in
# CI and when the package is built, never on an installed system, so nothing
# here is installed.

SHELL_SOURCES += $(filter-out tools/install.mk tools/render-wordmark,$(wildcard tools/*))
