#!/bin/bash
# list.sh <folders>: the images in the folders, given one per line, for the
# image picker: a path per line, sorted, each folder's own pictures and not
# those of folders inside it. A folder that is not there is skipped. The
# picker shows each image as itself; nova-theme, which sends its own rows,
# brings thumbnails.

mapfile -t folders <<<"${1:-}"
for folder in "${folders[@]}"; do
  [[ -d $folder ]] || continue
  find -L "$folder" -maxdepth 1 -type f -regextype posix-extended -iregex '.*\.(jpe?g|png|gif|bmp|webp|svg)' -print0 2>/dev/null
done | sort -z | tr '\0' '\n'
