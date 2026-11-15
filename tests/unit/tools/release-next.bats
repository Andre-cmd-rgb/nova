#!/usr/bin/env bats

# tools/release-next: which tag the fortnightly candidate gets.

load ../test_helper

next() { printf '%s\n' "$@" | "$REPO_ROOT/tools/release-next" --stdin; }
next_minor() { printf '%s\n' "$@" | "$REPO_ROOT/tools/release-next" --minor --stdin; }
next_major() { printf '%s\n' "$@" | "$REPO_ROOT/tools/release-next" --major --stdin; }

@test "the first candidate is the first beta" {
  [ "$(next)" = v1.0.0-beta.1 ]
  [ "$(next not-a-version v2)" = v1.0.0-beta.1 ]
}

@test "a beta or a release candidate is continued" {
  [ "$(next v1.0.0-beta.1 v1.0.0-beta.2)" = v1.0.0-beta.3 ]
  [ "$(next v1.0.0-beta.9 v1.0.0-beta.10)" = v1.0.0-beta.11 ]
  [ "$(next v1.0.0-beta.4 v1.0.0-rc.1)" = v1.0.0-rc.2 ]
}

@test "after a final release, the next patch version's first candidate" {
  [ "$(next v1.0.0-beta.4 v1.0.0)" = v1.0.1-rc.1 ]
  [ "$(next v1.0.9 v1.0.10 v1.0.10-rc.3)" = v1.0.11-rc.1 ]
}

@test "a final release outranks its own candidates, and higher versions outrank both" {
  [ "$(next v1.1.0 v1.1.0-rc.2)" = v1.1.1-rc.1 ]
  [ "$(next v1.2.0-rc.1 v1.1.0)" = v1.2.0-rc.2 ]
}

@test "--minor and --major start the next such version from the newest final release" {
  [ "$(next_minor v1.0.0)" = v1.1.0-rc.1 ]
  [ "$(next_major v1.0.0)" = v2.0.0-rc.1 ]
  [ "$(next_minor v1.0.0 v1.0.3)" = v1.1.0-rc.1 ]
  [ "$(next_major v1.4.2)" = v2.0.0-rc.1 ]
}

@test "a minor version already started is continued, by --minor and by the fortnight's run" {
  [ "$(next_minor v1.0.0 v1.1.0-rc.1)" = v1.1.0-rc.2 ]
  [ "$(next v1.0.0 v1.1.0-rc.1)" = v1.1.0-rc.2 ]
  [ "$(next_minor v1.0.0 v2.0.0-rc.1)" = v2.0.0-rc.2 ]
}

@test "--minor leaves a patch candidate behind, which is never made final" {
  [ "$(next_minor v1.0.0 v1.0.1-rc.2)" = v1.1.0-rc.1 ]
  [ "$(next_major v1.0.0 v1.1.0-rc.2)" = v2.0.0-rc.1 ]
}

@test "before the first final release, --minor and --major go on with its candidates" {
  [ "$(next_minor v1.0.0-beta.3)" = v1.0.0-beta.4 ]
  [ "$(next_major)" = v1.0.0-beta.1 ]
}

@test "anything else is refused" {
  run "$REPO_ROOT/tools/release-next" --patch
  [ "$status" -eq 2 ]
}
