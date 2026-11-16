#!/bin/bash
# files.sh: the files of the home folder that the menu's search finds.
#
#   files.sh list           list the home's files again, unless that was done
#                           in the last 30 s; the menu runs this as it opens
#   files.sh find <words>   the best five whose names hold every word: "d"
#                           for a folder or "f" for a file, a tab, and the
#                           path, a line each
#
# Nothing walks the home on a clock: the list is made as the menu opens, and
# a search reads it, in some 20 ms for 200,000 names; the first search ever,
# with no list yet, makes one first. Five folders down, and none hidden
# (.git, .cache, .config and every other), nor what builds fill: node_modules,
# __pycache__, and the inside of a folder tagged as a cache (CACHEDIR.TAG, as
# Cargo's target and ccache's are). The list is in the session's runtime
# folder, the user's alone, and gone at logout.

LIST=${XDG_RUNTIME_DIR:-/tmp}/nova/menu-files
FRESH=30
SHOWN=5

# A line a file: its type (d, f, l...), how deep, its name and its folder.
# The cache folders found are kept beside it, for the next walk to pass by:
# ccache's alone held 170,000 files, and taking them out after a walk that
# went in took a second each time.
make_list() {
  mkdir -p "${LIST%/*}" || return 1
  (
    flock -w 5 9 || exit 0
    local caches=() folder
    while IFS= read -r folder; do
      [[ -d $folder ]] && caches+=(-o -path "$(sed 's/[][*?\\]/\\&/g' <<<"$folder")")
    done < <(cat "$LIST.caches" 2>/dev/null)
    find "$HOME" -mindepth 1 -maxdepth 5 \( -name '.*' -o -name node_modules -o -name __pycache__ "${caches[@]}" \) -prune \
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

cmd_list() {
  local made
  made=$(stat -c %Y "$LIST" 2>/dev/null) && ((EPOCHSECONDS - made < FRESH)) && return 0
  make_list
}

# How good a find is, lower first: 0 for a name that is the search, with or
# without its extension; 1 for one that starts with it; 2 for one with a
# word that does (after a space, a dot, a - or a _), as a PDF has for "pdf";
# 3 for one that holds it anywhere; and a folder down adds one, so that
# ~/Documents comes before a doc folder deep in a project's sources. Then the
# better match, the shorter name, and the path. grep picks the names that
# hold the longest word, fast, and awk reads those alone.
cmd_find() {
  local term terms longest="" name
  read -ra terms <<<"$*"
  for term in "${terms[@]}"; do ((${#term} > ${#longest})) && longest=$term; done
  [[ -n $longest ]] || return 0
  [[ -s $LIST ]] || make_list
  name=$(sed 's/[][\.*^$]/\\&/g' <<<"$longest")
  grep -i -e $'^[^\t]*\t[^\t]*\t[^\t]*'"$name" "$LIST" 2>/dev/null | QUERY="$*" awk '
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
      stem = low
      if ($1 != "d") sub(/\.[^.]*$/, "", stem)
      words = " " low; gsub(/[._-]/, " ", words)
      if (stem == query || low == query) tier = 0
      else if (index(low, query) == 1) tier = 1
      else if (index(words, " " spaced)) tier = 2
      else tier = 3
      printf "%d\t%d\t%05d\t%s\t%s/%s\n", tier + $2, tier, length($3), ($1 == "d" ? "d" : "f"), $4, $3
    }' | LC_ALL=C sort -t $'\t' -k1,1n -k2,2n -k3,3n -k5,5 | head -n "$SHOWN" | cut -f 4-
}

case ${1:-} in
  list) cmd_list ;;
  find) shift; cmd_find "$@" ;;
  *) sed -n '2,/^$/s/^# \{0,1\}//p' "$0" >&2; exit 2 ;;
esac
