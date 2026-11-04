#!/bin/bash
# files.sh <job> <arguments>: the notification service's files, one job at a
# time in the order the service asks. In Nova's state folder,
#
#   notifications/              a JSON file for each toast on screen
#   notifications/history/      the files of the toasts gone, newest <limit>
#   notifications/images/       copies of their pictures, <stem>-<role>
#
# where a file is named <stem>.json, its toast's time and id.
#
#   show <dir> <images> <name> <json> [<from> <to>]...   a toast's file
#   forget <dir> <images> <stem>                         a toast's file gone
#   archive <dir> <history> <images> <name> <limit>      moved to the history
#   record <history> <images> <name> <json> <limit> [<from> <to>]...
#                                                        written there at once
#   sweep <dir> <history> <images>                       copies no file names
#   read <dir>                                           the files, a line each

# The pictures <from>, copied to <to>. A sender names the file, which may grow,
# block or be a pipe: it is read for 5 s and 5 MiB at most, into a file beside,
# and only one that ends within both takes the copy's place.
copy() {
  while (($# >= 2)); do
    if [[ -f $1 ]] && timeout 5 head -c 5242881 -- "$1" >"$2.tmp" 2>/dev/null \
      && (($(stat -c%s -- "$2.tmp") <= 5242880)); then
      mv -f -- "$2.tmp" "$2"
    else
      rm -f -- "$2.tmp"
    fi
    shift 2
  done
}

# The history down to its newest <limit> files, with their copies. The names
# sort by the time they start with.
trim() { # history images limit
  local stale
  ls -1 "$1" 2>/dev/null | sort -n | head -n "-$3" | while IFS= read -r stale; do
    rm -f "$1/$stale" "$2/${stale%.json}"-*
  done
}

job=$1
shift
case $job in
  show)
    mkdir -p "$1" "$2" || exit 0
    dir=$1 json=$4 name=$3
    shift 4
    copy "$@"
    printf '%s\n' "$json" >"$dir/$name"
    ;;
  forget)
    rm -f "$1/$3.json" "$2/$3"-*
    ;;
  archive)
    mkdir -p "$2" || exit 0
    # A toast replayed from the history has no file here, nor has the one
    # saying the history is empty.
    mv -f "$1/$4" "$2/$4" 2>/dev/null || exit 0
    trim "$2" "$3" "$5"
    ;;
  record)
    mkdir -p "$1" "$2" || exit 0
    history=$1 images=$2 name=$3 json=$4 limit=$5
    shift 5
    copy "$@"
    printf '%s\n' "$json" >"$history/$name" || exit 0
    trim "$history" "$images" "$limit"
    ;;
  sweep)
    # A restart can end a job between its copies and its file; a copy cut
    # short is left as .tmp.
    for image in "$3"/*; do
      [[ -e $image ]] || continue
      [[ $image == *.tmp ]] && { rm -f -- "$image"; continue; }
      name=${image##*/}
      name=${name%-*}
      [[ -e $1/$name.json || -e $2/$name.json ]] || rm -f "$image"
    done
    ;;
  read)
    # awk, not cat: a file a crash left without its last newline is not
    # joined to the next one's line.
    awk 1 "$1"/*.json 2>/dev/null || true
    ;;
esac
