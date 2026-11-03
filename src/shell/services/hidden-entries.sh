#!/bin/bash
# The desktop entries this desktop does not list, one desktop ID a line: an
# entry marked Hidden or NoDisplay, one whose OnlyShowIn names none of the
# desktops in $1 (a colon-separated list, as XDG_CURRENT_DESKTOP), and one
# whose NotShowIn names one of them. Only the [Desktop Entry] section counts.
#
# An ID is the file's path under its applications directory, with / as -.
# The first directory to have it wins, whatever the later ones say: the
# user's ~/.local/share, then $XDG_DATA_DIRS in order, then the Nix profile.
# AppLibrary runs this whenever the installed apps change; one awk reads all
# the files.

desktops=${1:-}

declare -A seen
files=()
ids=()

# The .desktop files under <dir>, in sorted order, whose ID no earlier file
# has taken.
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
  done < <(find "$dir" -type f -name '*.desktop' -print0 2>/dev/null | sort -z)
}

collect "$HOME/.local/share/applications"
IFS=":" read -ra data_dirs <<< "${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
for data_dir in "${data_dirs[@]}"; do
  collect "$data_dir/applications"
done
collect "$HOME/.nix-profile/share/applications"

(( ${#files[@]} > 0 )) || exit 0

# awk prints the place in the list of each hidden file, which gives its ID.
# It reads the files itself with getline, all in BEGIN, so that a file it
# cannot open is simply not hidden rather than the end of the scan.
while IFS= read -r at; do
  printf '%s\n' "${ids[at - 1]}"
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
  function is_hidden(file,   line, inside, hidden, only, notin, eq, key, value) {
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
    }
    close(file)
    return hidden || (only != "" && !names_desktop(only)) || (notin != "" && names_desktop(notin))
  }
  BEGIN {
    ndesktops = split(desktops, desktop, ":")
    for (at = 1; at < ARGC; at++) if (is_hidden(ARGV[at])) print at
    exit
  }
' "${files[@]}" 2>/dev/null)
