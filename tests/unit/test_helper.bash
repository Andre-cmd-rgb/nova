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

teardown_scratch() {
  [[ -n ${SCRATCH:-} && -d $SCRATCH ]] && rm -rf -- "$SCRATCH"
  return 0
}

# Create a file with its parent directories: write_file <path> [content]
write_file() {
  mkdir -p -- "$(dirname -- "$1")"
  printf '%s' "${2:-}" >"$1"
}
