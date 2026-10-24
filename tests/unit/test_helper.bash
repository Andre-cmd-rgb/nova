# Shared bats helpers for every unit test. Load with `load ../test_helper`.

REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
export REPO_ROOT
FIXTURES="$BATS_TEST_DIRNAME/fixtures"
export FIXTURES

# Every test gets its own scratch directory, removed afterwards.
setup_scratch() {
  SCRATCH=$(mktemp -d "${BATS_TMPDIR:-/tmp}/nova-test.XXXXXX")
  export SCRATCH
}

# A bare `! cmd` fails a bats test only as its last line; this fails it
# anywhere.
fails() { if "$@"; then return 1; fi; }

teardown_scratch() {
  [[ ! -d ${SCRATCH:-}/gnupg ]] || gpgconf --homedir "$SCRATCH/gnupg" --kill all 2>/dev/null || true
  [[ -n ${SCRATCH:-} && -d $SCRATCH ]] && rm -rf -- "$SCRATCH"
  return 0
}

# A signing key of the test's own, standing in for Nova's: TEST_KEY is its
# public half, armored as nova-keyring ships it, and test_sign <file> writes
# <file>.sig with it.
test_key() {
  export GNUPGHOME="$SCRATCH/gnupg" TEST_KEY="$SCRATCH/test-key.asc"
  mkdir -m 700 "$GNUPGHOME"
  gpg --batch --quiet --passphrase '' --quick-gen-key 'Nova test <test@example.org>' ed25519 sign never 2>/dev/null
  gpg --batch --armor --export >"$TEST_KEY"
}

test_sign() { gpg --batch --quiet --yes --detach-sign --output "$1.sig" -- "$1"; }

# Create a file with its parent directories: write_file <path> [content]
write_file() {
  mkdir -p -- "$(dirname -- "$1")"
  printf '%s' "${2:-}" >"$1"
}

# A scripted gum on PATH, for the setup screens: each prompt answers with the
# next of the replies given, "!1" being Esc and "!130" Ctrl+C, and a reply's
# \n separating the lines of a multiple choice. `gum style` prints its text to
# stderr. Each call is logged to $GUM_LOG, one line each.
stub_gum() { # reply...
  mkdir -p "$SCRATCH/gum-bin"
  printf '%s\n' "$@" >"$SCRATCH/gum-replies"
  : >"$SCRATCH/gum-log"
  cat >"$SCRATCH/gum-bin/gum" <<'GUM'
#!/bin/bash
printf '%s\n' "$*" >>"$GUM_LOG"
case $1 in
  style)
    shift
    while [[ ${1:-} == --* ]]; do shift 2; done
    printf '%s\n' "$@" >&2
    exit 0
    ;;
  filter) cat >"$GUM_LOG.filter" ;;
esac
if [[ ! -s $GUM_REPLIES ]]; then
  echo "gum stub: no reply left for: $*" >&2
  exit 99
fi
reply=$(head -n 1 "$GUM_REPLIES")
sed -i 1d "$GUM_REPLIES"
case $reply in
  '!'*) exit "${reply#!}" ;;
  *) [[ $1 == confirm ]] || printf '%b\n' "$reply" ;;
esac
GUM
  chmod +x "$SCRATCH/gum-bin/gum"
  export GUM_REPLIES="$SCRATCH/gum-replies" GUM_LOG="$SCRATCH/gum-log" PATH="$SCRATCH/gum-bin:$PATH"
}

# The replies stub_gum has not given yet.
gum_replies_left() { wc -l <"$GUM_REPLIES"; }
