#!/bin/bash
# Both suites. Neither touches /boot or /usr/share.
set -uo pipefail
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
status=0
for suite in limine splash; do
  printf '\033[1m%s\033[0m\n' "$suite"
  "$HERE/$suite.sh" || status=1
  echo
done
exit $status
