#!/bin/bash

# Deletes the clipboard images no history entry names any more: dropped off
# the end of the history, removed from it, or cleared with it. The shell runs
# this with the paths its history holds. An image written in the last minute
# stays, since capture.sh writes the file before the shell adds its entry;
# capture.sh touches one it reuses for the same reason.

set -euo pipefail

IMAGE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/nova/clipboard-images"
[[ -d $IMAGE_DIR ]] || exit 0

# By name, which is the image's hash: the directory a path was written under
# may be spelled another way since.
declare -A keep=()
for path in "$@"; do
  [[ -n ${path##*/} ]] && keep[${path##*/}]=1
done

while IFS= read -r -d '' file; do
  [[ -n ${keep[${file##*/}]:-} ]] || rm -f -- "$file"
done < <(find "$IMAGE_DIR" -maxdepth 1 -type f -mmin +1 -print0)
