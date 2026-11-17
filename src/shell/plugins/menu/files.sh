#!/bin/bash
# files.sh: the files of the home folder that the menu's search finds, those
# opened lately first.
#
#   files.sh find <words>   the best five whose names hold every word: "d"
#                           for a folder or "f" for a file, a tab, and the
#                           path, a line each
#   files.sh list           list the home's files again now, unless that was
#                           done in the last five minutes
#
# Nothing walks the home on a clock, nor as the menu opens: a search reads
# the list, in some 10 ms for 36,000 names, and a list older than five minutes
# is made again behind it, for the searches after; a new file is found from
# then. The first search, with no list yet, waits for one, and so does one
# that comes while a walk is going. Five folders down, and none hidden (.git,
# .cache, .config and every other), nor what builds fill: node_modules,
# __pycache__, and the inside of a folder tagged as a cache (CACHEDIR.TAG, as
# Cargo's target and ccache's are); nor anything mounted under the home, which
# may be a network's, and hang the walk if it is gone. The list is in the
# session's runtime folder, the user's alone, and gone at logout. A file
# opened lately is found wherever it is in the home, hidden or deep.

LIST=${XDG_RUNTIME_DIR:-/tmp}/nova/menu-files
RECENT=${XDG_DATA_HOME:-$HOME/.local/share}/recently-used.xbel
MOUNTS=${NOVA_MOUNTS:-/proc/self/mounts}
FRESH=300
SHOWN=5

fresh() {
  local made
  made=$(stat -c %Y "$LIST" 2>/dev/null) && ((EPOCHSECONDS - made < FRESH))
}

# A path as find's -path takes it: its own wildcards and backslashes as
# themselves.
literal() {
  sed 's/[][*?\\]/\\&/g' <<<"$1"
}

# What is mounted below the home, from the mount table, whose spaces, tabs,
# newlines and backslashes it writes as octal escapes. Not -xdev, which
# would pass by a Btrfs subvolume too, and those are no mounts.
mounts_below_home() {
  local point
  while read -r _ point _; do
    point=${point//\\040/ } point=${point//\\011/$'\t'} point=${point//\\012/$'\n'} point=${point//\\134/\\}
    [[ $point == "$HOME"/* ]] && printf '%s\n' "$point"
  done <"$MOUNTS"
}

# A line a file: its type (d, f, l...), how deep, its name and its folder.
# The cache folders found are kept beside it, for the next walk to pass by:
# ccache's alone held 170,000 files, and taking them out after a walk that
# went in took a second each time. One walk at a time: <wait> is flock's say
# on one already going (-n: leave it to that one), and a list made while
# this waited is the one.
make_list() { # wait
  mkdir -p "${LIST%/*}" || return 1
  (
    flock "$@" 9 || exit 0
    fresh && exit 0
    local skip=() folder
    while IFS= read -r folder; do
      [[ -d $folder ]] && skip+=(-o -path "$(literal "$folder")")
    done < <(cat "$LIST.caches" 2>/dev/null; mounts_below_home)
    find "$HOME" -mindepth 1 -maxdepth 5 \( -name '.*' -o -name node_modules -o -name __pycache__ "${skip[@]}" \) -prune \
      -o -printf '%y\t%d\t%f\t%h\n' 2>/dev/null >"$LIST.new"
    if grep -q $'\tCACHEDIR.TAG\t' "$LIST.new"; then
      awk -F '\t' -v caches="$LIST.caches" '
        NR == FNR { if ($3 == "CACHEDIR.TAG") { cache[$4] = 1; print $4 >>caches } next }
        { for (folder = $4; folder ~ /\//; sub(/\/[^\/]*$/, "", folder)) if (folder in cache) next; print }
      ' "$LIST.new" "$LIST.new" >"$LIST.kept" && mv -f "$LIST.kept" "$LIST.new"
    fi
    mv -f "$LIST.new" "$LIST"
  ) 9>"$LIST.lock"
}

# The files opened lately whose names hold every word, newest first, as the
# list's lines are, with how recent each is after them (1 for the newest):
# from recently-used.xbel, where GTK's apps (Files, Loupe, Text Editor...)
# note each file they open. Those in the home alone, hidden or deep ones
# too, but not below anything mounted in it, which may be a network's and
# hang the look; and only those still there. awk reads the file and keeps
# the names that may match (in the C locale, as it decodes bytes, so a
# capital beyond ASCII may keep one out, which the home's list still finds);
# then only those are looked at, in some 2 ms all told.
recent() { # words
  [[ -r $RECENT ]] || return 0
  local found=() mounts=() point line path type relative slashes rank=0
  # The href is a URI written in XML: its entities first, then its %XX.
  mapfile -t found < <(QUERY=$* LC_ALL=C awk '
    BEGIN {
      for (i = 0; i < 256; i++) byte[sprintf("%02X", i)] = byte[sprintf("%02x", i)] = sprintf("%c", i)
      count = split(tolower(ENVIRON["QUERY"]), terms, " ")
    }
    /<bookmark href="file:\/\// && match($0, /href="file:\/\/[^"]*"/) {
      uri = substr($0, RSTART + 13, RLENGTH - 14)
      if (!match($0, / modified="[^"]*"/)) next
      when = substr($0, RSTART + 11, RLENGTH - 12)
      gsub(/&apos;/, "\047", uri); gsub(/&quot;/, "\"", uri); gsub(/&lt;/, "<", uri); gsub(/&gt;/, ">", uri); gsub(/&amp;/, "\\&", uri)
      path = ""
      while (match(uri, /%[0-9A-Fa-f][0-9A-Fa-f]/)) {
        path = path substr(uri, 1, RSTART - 1) byte[substr(uri, RSTART + 1, 2)]
        uri = substr(uri, RSTART + 3)
      }
      path = path uri
      name = tolower(path); sub(/.*\//, "", name)
      for (i = 1; i <= count; i++) if (!index(name, terms[i])) next
      print when "\t" path
    }' "$RECENT" 2>/dev/null | LC_ALL=C sort -r)
  ((${#found[@]})) || return 0
  while IFS= read -r point; do mounts+=("$point"); done < <(mounts_below_home)
  for line in "${found[@]}"; do
    path=${line#*$'\t'}
    [[ $path == "$HOME"/* && -e $path ]] || continue
    for point in "${mounts[@]}"; do [[ $path == "$point"/* ]] && continue 2; done
    if [[ -d $path ]]; then type=d; else type=f; fi
    relative=${path#"$HOME"/} slashes=${relative//[!\/]/}
    printf '%s\t%d\t%s\t%s\t%d\n' "$type" $((${#slashes} + 1)) "${path##*/}" "${path%/*}" $((++rank))
  done
}

# How good a find is, lower first: 0 for a name that is the search, with or
# without its extension; 1 for one that starts with it; 2 for one with a
# word that does (after a space, a dot, a - or a _), as a PDF has for "pdf";
# 3 for one that holds it anywhere; and a folder down adds one, so that
# ~/Documents comes before a doc folder deep in a project's sources. Then the
# better match, the shorter name, and the path. A file opened lately whose
# name is the search, or starts with it, or has a word that does, comes
# before all of those: by how good, then the newest. grep picks the names
# that hold the longest word, fast, and awk reads those alone.
cmd_find() {
  local term terms longest="" name
  read -ra terms <<<"$*"
  for term in "${terms[@]}"; do ((${#term} > ${#longest})) && longest=$term; done
  [[ -n $longest ]] || return 0
  if [[ ! -s $LIST ]]; then
    make_list -w 120
  elif ! fresh; then
    make_list -n </dev/null >/dev/null 2>&1 &
    disown
  fi
  name=$(literal "$longest")
  { recent "$@"; grep -i -e $'^[^\t]*\t[^\t]*\t[^\t]*'"$name" "$LIST" 2>/dev/null; } | QUERY="$*" awk '
    BEGIN {
      FS = "\t"
      query = tolower(ENVIRON["QUERY"])
      gsub(/[[:space:]]+/, " ", query); sub(/^ /, "", query); sub(/ $/, "", query)
      count = split(query, terms, " ")
      spaced = query; gsub(/[._-]/, " ", spaced)
    }
    {
      low = tolower($3)
      for (i = 1; i <= count; i++) if (!index(low, terms[i])) next
      path = $4 "/" $3
      if (path in seen) next
      seen[path] = 1
      stem = low
      if ($1 != "d") sub(/\.[^.]*$/, "", stem)
      words = " " low; gsub(/[._-]/, " ", words)
      if (stem == query || low == query) tier = 0
      else if (index(low, query) == 1) tier = 1
      else if (index(words, " " spaced)) tier = 2
      else tier = 3
      type = $1 == "d" ? "d" : "f"
      if ($5 != "" && tier < 3) printf "0\t%d\t%d\t%05d\t%s\t%s\n", tier, $5, length($3), type, path
      else printf "1\t%d\t%d\t%05d\t%s\t%s\n", tier + $2, tier, length($3), type, path
    }' | LC_ALL=C sort -t $'\t' -k1,1n -k2,2n -k3,3n -k4,4n -k6,6 | head -n "$SHOWN" | cut -f 5-
}

case ${1:-} in
  find) shift; cmd_find "$@" ;;
  list) make_list -w 120 ;;
  *) sed -n '2,/^$/s/^# \{0,1\}//p' "$0" >&2; exit 2 ;;
esac
