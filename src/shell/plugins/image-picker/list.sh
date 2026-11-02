#!/bin/bash
# list.sh <folders>: the images in the folders, given one per line, for the
# image picker: a path per line, sorted, each folder's own pictures and not
# those of folders inside it. A folder that is not there is skipped. The
# picker shows each image as itself; nova-theme, which sends its own rows,
# brings thumbnails.

while IFS= read -r dir; do
  [[ -n $dir && -d $dir ]] || continue
  find -L "$dir" -maxdepth 1 -type f \
    \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.gif' -o -iname '*.bmp' -o -iname '*.webp' -o -iname '*.svg' \) \
    -print0 2>/dev/null
done <<<"${1:-}" | sort -z | tr '\0' '\n'
