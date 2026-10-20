# The release's install test: a stick image, an unattended install in QEMU and
# the installed system's first boot. Run by release.yml, never by make test.

SHELL_SOURCES += tests/install/run tests/install/after tests/install/probe
