# The shell's logic tests run Quickshell against an installed tree, so they are
# not part of `make test`; CI runs them after its scratch install
# (.github/workflows/ci.yml). Listed here so `make lint` covers the runner.

SHELL_SOURCES += tests/qml/run
