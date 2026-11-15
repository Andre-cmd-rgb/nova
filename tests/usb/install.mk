# The stick test writes a loop device as root, so it is not part of `make test`;
# CI runs it on its own machine (.github/workflows/ci.yml, job stick). Listed
# here so `make lint` covers it.

SHELL_SOURCES += tests/usb/stick-test
