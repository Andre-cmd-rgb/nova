# Maintainer tools: release pinning, the signed repository, the keyring, the ISO,
# the site, the shell's plugin index and the offscreen check of its windows,
# the check of X11 games in a nested Hyprland (with its C half), and the three
# Python ones that make committed files (the wordmark, the emoji list, the
# background in the documentation's pictures). They run in CI, when the
# package is built or by hand, never on an installed system, so nothing here is
# installed; shellcheck reads the shell ones.

SHELL_SOURCES += $(filter-out tools/install.mk tools/render-wordmark tools/emoji-list tools/xwayland-game-check.c,$(wildcard tools/*))
