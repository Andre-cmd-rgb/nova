#!/usr/bin/env bats

# tools/release-next: which tag the fortnightly candidate gets.

load ../test_helper

next() { printf '%s\n' "$@" | "$REPO_ROOT/tools/release-next" --stdin; }

@test "the first candidate is the first beta" {
  [ "$(next)" = v1.0.0-beta.1 ]
  [ "$(next not-a-version v2)" = v1.0.0-beta.1 ]
}

@test "a beta or a release candidate is continued" {
  [ "$(next v1.0.0-beta.1 v1.0.0-beta.2)" = v1.0.0-beta.3 ]
  [ "$(next v1.0.0-beta.9 v1.0.0-beta.10)" = v1.0.0-beta.11 ]
  [ "$(next v1.0.0-beta.4 v1.0.0-rc.1)" = v1.0.0-rc.2 ]
}

@test "after a final release, the next minor version's first candidate" {
  [ "$(next v1.0.0-beta.4 v1.0.0)" = v1.1.0-rc.1 ]
  [ "$(next v1.9.0 v1.10.0 v1.10.0-rc.3)" = v1.11.0-rc.1 ]
}

@test "a final release outranks its own candidates, and higher versions outrank both" {
  [ "$(next v1.1.0 v1.1.0-rc.2)" = v1.2.0-rc.1 ]
  [ "$(next v1.2.0-rc.1 v1.1.0)" = v1.2.0-rc.2 ]
}
