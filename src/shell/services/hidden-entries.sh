#!/bin/bash
# Two lists of desktop entries, from one read of them, a line each:
#
#   hidden <id>    an entry this desktop does not list: one marked Hidden or
#                  NoDisplay, one whose OnlyShowIn names none of the desktops
#                  in $1 (a colon-separated list, as XDG_CURRENT_DESKTOP), and
#                  one whose NotShowIn names one of them
#   discrete <id>  an entry that asks to run on the discrete GPU:
#                  PrefersNonDefaultGPU=true, or KDE's older
#                  X-KDE-RunOnDiscreteGpu=true
#
# Only the [Desktop Entry] section counts. An ID is the file's path under its
# applications directory, with / as -. The first directory to have it wins,
# whatever the later ones say: the user's ~/.local/share, then $XDG_DATA_DIRS
# in order, then the Nix profile. AppLibrary runs this whenever the installed
# apps change; one awk reads all the files, each once.

desktops=${1:-}

declare -A seen
files=()
ids=()

# The .desktop files under <dir>, in sorted order, whose ID no earlier file
# has taken: files, and links to files, which is how Flatpak exports its.
collect() {
  local dir=$1 file id
  [[ -d $dir ]] || return
  while IFS= read -r -d '' file; do
    id=${file#"$dir"/}
    id=${id%.desktop}
    id=${id//\//-}
    [[ -n ${seen[$id]+set} ]] && continue
    seen[$id]=1
    files+=("$file")
    ids+=("$id")
  done < <(find "$dir" -name '*.desktop' \( -type f -o -xtype f \) -print0 2>/dev/null | sort -z)
}

collect "$HOME/.local/share/applications"
IFS=":" read -ra data_dirs <<< "${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
for data_dir in "${data_dirs[@]}"; do
  collect "$data_dir/applications"
done
collect "$HOME/.nix-profile/share/applications"

(( ${#files[@]} > 0 )) || exit 0

# awk prints, for each file it picks, which list and the file's place in the
# list of files, which gives its ID. It reads the files itself with getline,
# all in BEGIN, so that a file it cannot open is simply in neither list rather
# than the end of the scan.
while read -r list at; do
  printf '%s %s\n' "$list" "${ids[at - 1]}"
done < <(awk -v desktops="$desktops" '
  # Whether the ;-separated <list> names one of the desktops.
  function names_desktop(list,   count, entries, i, j) {
    count = split(list, entries, ";")
    for (i = 1; i <= ndesktops; i++) {
      if (desktop[i] == "") continue
      for (j = 1; j <= count; j++) if (entries[j] == desktop[i]) return 1
    }
    return 0
  }
  # Prints the lists the file at <at> is in.
  function read_entry(file, at,   line, inside, hidden, only, notin, prefers, eq, key, value) {
    while ((getline line < file) > 0) {
      # NUL bytes are dropped, as bash does when it reads a line.
      gsub(/\0/, "", line)
      sub(/\r$/, "", line)
      if (line ~ /^\[.*\]$/) { inside = line == "[Desktop Entry]"; continue }
      eq = index(line, "=")
      if (!inside || !eq) continue
      key = substr(line, 1, eq - 1)
      value = substr(line, eq + 1)
      if (key == "Hidden" || key == "NoDisplay") { if (value == "true") hidden = 1 }
      else if (key == "OnlyShowIn") only = value
      else if (key == "NotShowIn") notin = value
      else if ((key == "PrefersNonDefaultGPU" || key == "X-KDE-RunOnDiscreteGpu") && value == "true") prefers = 1
    }
    close(file)
    if (hidden || (only != "" && !names_desktop(only)) || (notin != "" && names_desktop(notin))) print "hidden", at
    if (prefers) print "discrete", at
  }
  BEGIN {
    ndesktops = split(desktops, desktop, ":")
    for (at = 1; at < ARGC; at++) read_entry(ARGV[at], at)
    exit
  }
' "${files[@]}" 2>/dev/null)
