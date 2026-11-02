# Maintainer tools: release pinning, the signed repository, the keyring, the ISO,
# the shell's plugin index and the offscreen check of its windows, and the two
# Python ones that make committed files (the wordmark, the emoji list). They
# run in CI, when the package is built or by hand, never on an installed
# system, so nothing here is installed; shellcheck reads the shell ones.

SHELL_SOURCES += $(filter-out tools/install.mk tools/render-wordmark tools/emoji-list %.asc,$(wildcard tools/*))
