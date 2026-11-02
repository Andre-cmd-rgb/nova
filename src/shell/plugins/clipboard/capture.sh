#!/bin/bash
# capture.sh [text | image/<type>]: what was copied as a clipboard history
# entry, a line of JSON for the clipboard plugin. The wl-paste watchers run
# it at every copy, with the copy on stdin and its kind as $1; with no
# argument it reads the clipboard itself, as the shell starts. A copy an app
# marks as a password makes no entry, nor does text over 1 MiB, which stays
# on the clipboard but would be held in the shell's memory and written out
# whole at every copy. An image is kept in clipboard-images under its hash.

set -o pipefail

images=${XDG_STATE_HOME:-$HOME/.local/state}/nova/clipboard-images
mkdir -p "$images"

types=$(wl-paste --list-types 2>/dev/null || true)
if [[ ${CLIPBOARD_STATE:-} == sensitive ]] || grep -qx 'x-kde-passwordManagerHint' <<<"$types"; then
  exit 0
fi

# The image on stdin, of type $1. The same image copied again keeps its file,
# touched: prune-images.sh spares a file written in the last minute, as its
# entry may still be on its way.
image() {
  local type=$1 ext tmp file
  ext=${type#image/}
  [[ $ext == jpeg ]] && ext=jpg
  tmp=$(mktemp --tmpdir="$images" clipboard.XXXXXX) || return 0
  cat >"$tmp"
  if [[ ! -s $tmp ]]; then
    rm -f "$tmp"
    return 0
  fi
  file=$images/$(sha256sum "$tmp" | cut -d' ' -f1).$ext
  if [[ -e $file ]]; then
    rm -f "$tmp"
    touch -- "$file"
  else
    mv "$tmp" "$file"
  fi
  jq -cn --arg mime "$type" --arg path "$file" --arg captured_at "$(date +'%A %H:%M')" \
    '{type:"image", mime:$mime, path:$path, capturedAt:$captured_at}'
}

# The text on stdin. It is UTF-8 unless it starts with a UTF-16 byte order
# mark, or looks like UTF-16 without one: an even length, with a NUL in one
# byte of three in four 16-bit units or more and in the other byte of fewer
# than one in four. That is a guess, as NUL-separated bytes look the same,
# so it is dropped if what it decodes to holds control characters.
text() {
  perl -MEncode=decode,FB_CROAK,LEAVE_SRC -MJSON::PP=encode_json -0777 -e '
    my $raw = <STDIN>;
    exit unless length $raw;
    exit if length $raw > 1 << 20;

    my ($encoding, $guessed);
    if ($raw =~ /^(?:\xFF\xFE|\xFE\xFF)/) {
      $encoding = "UTF-16";
    } elsif (length($raw) % 2 == 0 && index($raw, "\0") >= 0) {
      my $units = length($raw) / 2;
      # Fewer NULs than three in four units cannot fill either byte, so the
      # bytes are not split apart for nothing.
      if (($raw =~ tr/\0//) * 4 >= $units * 3) {
        (my $first = $raw) =~ s/(.)./$1/sg;
        (my $second = $raw) =~ s/.(.)/$1/sg;
        my $in_first = ($first =~ tr/\0//) * 4;
        my $in_second = ($second =~ tr/\0//) * 4;
        if ($in_second >= $units * 3 && $in_first < $units) {
          ($encoding, $guessed) = ("UTF-16LE", 1);
        } elsif ($in_first >= $units * 3 && $in_second < $units) {
          ($encoding, $guessed) = ("UTF-16BE", 1);
        }
      }
    }

    my $text = $encoding ? eval { decode($encoding, $raw, FB_CROAK | LEAVE_SRC) } : undef;
    undef $text if $guessed && defined $text && $text =~ /[\x00-\x08\x0E-\x1A\x1C-\x1F]/;
    $text = decode("UTF-8", $raw) unless defined $text;
    print "{\"type\":\"text\",\"text\":", encode_json($text), "}\n";
  '
}

case ${1:-} in
  text) text; exit 0 ;;
  image/*) image "$1"; exit 0 ;;
esac

# No argument: the clipboard as it is, an image if it offers one.
for type in image/png image/jpeg image/webp image/gif image/bmp image/tiff; do
  if grep -qx "$type" <<<"$types"; then
    timeout 2s wl-paste --type "$type" 2>/dev/null | image "$type"
    exit 0
  fi
done
if grep -q '^text/' <<<"$types" || grep -qxE 'UTF8_STRING|STRING' <<<"$types"; then
  wl-paste --type text --no-newline 2>/dev/null | text
fi
