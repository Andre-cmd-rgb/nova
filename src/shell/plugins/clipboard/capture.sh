#!/bin/bash
# capture.sh [text | image/<type>]: a copy as an entry of the clipboard's
# history, printed as a line of JSON for History.qml. The two wl-paste
# watchers run it at every copy, the copy on stdin and its kind as $1; with
# no argument, as the shell starts, it reads the clipboard itself, an image
# if it offers one. Nothing is printed for a copy an app marks as a
# password, nor for text over 1 MiB, which stays on the clipboard but would
# be held in the shell's memory and written out whole at every copy.

set -o pipefail

store=${XDG_STATE_HOME:-$HOME/.local/state}/nova/clipboard-images
mkdir -p "$store"

offered=$(wl-paste --list-types 2>/dev/null || true)
[[ ${CLIPBOARD_STATE:-} == sensitive ]] && exit 0
grep -qx 'x-kde-passwordManagerHint' <<<"$offered" && exit 0

# The image on stdin, of type $1, kept in the store under its hash. The same
# image copied again keeps its file, touched, as prune-images.sh spares a
# file written in the last minute: its entry may still be on its way.
save_image() {
  local mime=$1 suffix=${1#image/} part kept
  [[ $suffix == jpeg ]] && suffix=jpg
  part=$(mktemp --tmpdir="$store" clipboard.XXXXXX) || return 0
  cat >"$part"
  if [[ ! -s $part ]]; then
    rm -f "$part"
    return 0
  fi
  kept=$store/$(sha256sum "$part" | cut -d' ' -f1).$suffix
  if [[ -e $kept ]]; then
    rm -f "$part"
    touch -- "$kept"
  else
    mv "$part" "$kept"
  fi
  jq -cn --arg mime "$mime" --arg path "$kept" --arg at "$(date +'%A %H:%M')" \
    '{type: "image", mime: $mime, path: $path, capturedAt: $at}'
}

# The text on stdin, decoded. UTF-8, unless it starts with a UTF-16 byte
# order mark, or looks like UTF-16 without one: an even length, with a NUL
# in one byte of three in four 16-bit units or more and in the other byte
# of fewer than one in four. That is a guess, as bytes kept apart by NULs
# look the same, so the guess is dropped when it decodes to control
# characters.
save_text() {
  perl -MEncode=decode,FB_CROAK,LEAVE_SRC -MJSON::PP=encode_json -0777 -e '
    my $bytes = <STDIN>;
    exit if length($bytes) == 0 || length($bytes) > 1 << 20;

    my ($utf16, $guess) = ("", 0);
    if ($bytes =~ /^(?:\xFF\xFE|\xFE\xFF)/) {
      $utf16 = "UTF-16";
    } elsif (length($bytes) % 2 == 0 && index($bytes, "\0") >= 0) {
      my $units = length($bytes) / 2;
      # With fewer NULs than three in four units, neither byte can be
      # filled with them: the bytes are not taken apart for nothing.
      if (($bytes =~ tr/\0//) * 4 >= $units * 3) {
        my ($even, $odd) = ($bytes, $bytes);
        $even =~ s/(.)./$1/sg;
        $odd =~ s/.(.)/$1/sg;
        my $nul_even = ($even =~ tr/\0//) * 4;
        my $nul_odd = ($odd =~ tr/\0//) * 4;
        if ($nul_odd >= $units * 3 && $nul_even < $units) {
          ($utf16, $guess) = ("UTF-16LE", 1);
        } elsif ($nul_even >= $units * 3 && $nul_odd < $units) {
          ($utf16, $guess) = ("UTF-16BE", 1);
        }
      }
    }

    my $text;
    $text = eval { decode($utf16, $bytes, FB_CROAK | LEAVE_SRC) } if $utf16;
    undef $text if $guess && defined $text && $text =~ /[\x00-\x08\x0E-\x1A\x1C-\x1F]/;
    $text = decode("UTF-8", $bytes) if !defined $text;
    print "{\"type\":\"text\",\"text\":", encode_json($text), "}\n";
  '
}

case ${1:-} in
  text)
    save_text
    exit 0
    ;;
  image/*)
    save_image "$1"
    exit 0
    ;;
esac

for mime in image/png image/jpeg image/webp image/gif image/bmp image/tiff; do
  grep -qx "$mime" <<<"$offered" || continue
  timeout 2s wl-paste --type "$mime" 2>/dev/null | save_image "$mime"
  exit 0
done
if grep -q '^text/' <<<"$offered" || grep -qxE 'UTF8_STRING|STRING' <<<"$offered"; then
  wl-paste --type text --no-newline 2>/dev/null | save_text
fi
