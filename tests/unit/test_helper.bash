# Shared bats helpers for every unit test. Load with `load ../test_helper`.

REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
export REPO_ROOT
FIXTURES="$BATS_TEST_DIRNAME/fixtures"
export FIXTURES

# A session exports these with the real home's folders: a test that gives a
# tool a scratch HOME would still have it read and write the real ones.
unset XDG_STATE_HOME XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME

# No test reaches the desktop it runs on. A command a test forgot to stub
# would otherwise act on it: one test's "VS Code is waiting for you" was a
# real notification at every run of the suite. The session's bus is one that
# is not there, and the scratch has the runtime directory, where the shell's
# and Hyprland's sockets would be.
export DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent/nova-test-session-bus
unset WAYLAND_DISPLAY DISPLAY HYPRLAND_INSTANCE_SIGNATURE

# Every test gets its own scratch directory, removed afterwards, with its own
# runtime directory in it.
setup_scratch() {
  SCRATCH=$(mktemp -d "${BATS_TMPDIR:-/tmp}/nova-test.XXXXXX")
  export SCRATCH
  mkdir -m 700 "$SCRATCH/xdg-runtime"
  export XDG_RUNTIME_DIR="$SCRATCH/xdg-runtime"
}

# A bare `! cmd` fails a bats test only as its last line; this fails it
# anywhere.
fails() { if "$@"; then return 1; fi; }

# Whether the process <pid> runs: there, and not a zombie. kill -0 finds a
# zombie too, and where the first process reaps nothing (a container's, as
# GitHub's is) an orphan that ended stays one.
running() { # pid
  local stat
  stat=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
  stat=${stat##*) }
  [[ ${stat%% *} != Z ]]
}

# Each gpg home a test made ($SCRATCH/gnupg, gnupg-other) has its agent
# stopped, and the folder gpg made for its sockets in the runtime directory
# goes with it.
teardown_scratch() {
  local home
  for home in "${SCRATCH:-}"/gnupg*/; do
    [[ -d $home ]] || continue
    gpgconf --homedir "${home%/}" --kill all 2>/dev/null || true
    gpgconf --homedir "${home%/}" --remove-socketdir 2>/dev/null || true
  done
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

# The screens a test saved, without their colours, to grep as they read.
uncolour() { sed -i $'s/\e\\[[0-9;]*m//g' "$@"; }

# The replies stub_gum has not given yet.
gum_replies_left() { wc -l <"$GUM_REPLIES"; }
