#!/usr/bin/env bats

# The unit tests' own rules (tests/unit/test_helper.bash): they refuse to run
# as root, where the programs that run as root ignore their test seams and
# would act on the computer. Root here is a user namespace's (unshare -r),
# which can change nothing outside it; where there is none, the test says so.

load ../test_helper

@test "the unit tests refuse to run as root, saying why" {
  unshare -r true 2>/dev/null || skip "no user namespaces here"
  setup_scratch
  printf '#!/usr/bin/env bats\nload %s\n@test "x" { true; }\n' "$REPO_ROOT/tests/unit/test_helper" >"$SCRATCH/root.bats"
  run unshare -r bats "$SCRATCH/root.bats" </dev/null
  teardown_scratch
  [ "$status" -ne 0 ]
  [[ $output == *"do not run as root"* ]]
}
