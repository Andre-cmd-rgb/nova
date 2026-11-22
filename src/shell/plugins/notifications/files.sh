#!/bin/bash
# files.sh <job> <arguments>: the notification service's files, one job at a
# time in the order the service asks. In Nova's state folder,
#
#   notifications/              a JSON file for each toast on screen
#   notifications/history/      the files of the toasts gone, newest <limit>
#   notifications/images/       copies of their pictures, <stem>-<role>
#
# where a file is named <stem>.json, its toast's time and id; and in Nova's
# runtime folder, <commands>, $XDG_RUNTIME_DIR/nova/notifications/, what the
# toasts run (Commands.qml): a sender's file under the name its hint gives,
# 32 hex digits, until a toast claims it as <stem>.json.
#
#   show <dir> <images> <name> <json> [<from> <to>]...   a toast's file
#   forget <dir> <images> <commands> <stem>              a toast's files gone
#   archive <dir> <history> <images> <commands> <name> <limit>
#                                                        moved to the history
#   record <history> <images> <commands> <name> <json> <limit> [<from> <to>]...
#                                                        written there at once
#   claim <commands> <name> <stem>                       a sender's file, now
#                                                        toast <stem>'s
#   sweep <dir> <history> <images> <commands>            what no file names
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

# The history down to its newest <limit> files, with their copies and what
# they run. The names sort by the time they start with.
trim() { # history images commands limit
  local stale
  ls -1 "$1" 2>/dev/null | sort -n | head -n "-$4" | while IFS= read -r stale; do
    rm -f "$1/$stale" "$2/${stale%.json}"-*
    [[ -z $3 ]] || rm -f "$3/$stale"
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
    rm -f "$1/$4.json" "$2/$4"-*
    [[ -z $3 ]] || rm -f "$3/$4.json"
    ;;
  archive)
    mkdir -p "$2" || exit 0
    # A toast replayed from the history has no file here, nor has the one
    # saying the history is empty.
    mv -f "$1/$5" "$2/$5" 2>/dev/null || exit 0
    trim "$2" "$3" "$4" "$6"
    ;;
  record)
    mkdir -p "$1" "$2" || exit 0
    history=$1 images=$2 commands=$3 name=$4 json=$5 limit=$6
    shift 6
    copy "$@"
    printf '%s\n' "$json" >"$history/$name" || exit 0
    trim "$history" "$images" "$commands" "$limit"
    ;;
  claim)
    # The names as the service checked them: neither can lead out of the
    # folder. A replacement's file takes the place of the one before.
    [[ -n $1 && $2 =~ ^[0-9a-f]{32}$ && $3 =~ ^[0-9]+-[0-9]+$ ]] || exit 0
    mv -f -- "$1/$2" "$1/$3.json" 2>/dev/null || true
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
    [[ -n $4 ]] || exit 0
    # What no toast's file names, and a sender's file no toast claimed within
    # a minute: the shell was away, or the call failed.
    for kept in "$4"/*.json; do
      [[ -e $kept ]] || continue
      name=${kept##*/}
      [[ -e $1/$name || -e $2/$name ]] || rm -f -- "$kept"
    done
    find "$4" -maxdepth 1 -type f -regextype posix-extended -regex '.*/[0-9a-f]{32}' -mmin +1 -delete 2>/dev/null || true
    ;;
  read)
    # awk, not cat: a file a crash left without its last newline is not
    # joined to the next one's line.
    awk 1 "$1"/*.json 2>/dev/null || true
    ;;
esac
