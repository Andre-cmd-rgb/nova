#!/usr/bin/env bats

# tools/release-notes: a release's notes, from the commits since the release
# before it, in a scratch repository with tags of its own.

load ../test_helper

setup() {
  setup_scratch
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  export GIT_AUTHOR_NAME=Nova GIT_AUTHOR_EMAIL=nova@example.org
  export GIT_COMMITTER_NAME=Nova GIT_COMMITTER_EMAIL=nova@example.org
  cd "$SCRATCH"
  git init -q -b main .
}

teardown() { teardown_scratch; }

commit() { git commit -q --allow-empty -m "$1"; }
notes() { "$REPO_ROOT/tools/release-notes" "$1" https://github.com/someone/nova; }

@test "the first tag has nothing before it, and points at the README" {
  commit 'feat(shell): a bar'
  git tag v1.0.0-rc.1
  run notes v1.0.0-rc.1
  [ "$status" -eq 0 ]
  [[ $output == "The first release in this numbering"* ]]
  [[ $output == *"(https://github.com/someone/nova#readme)"* ]]
}

@test "a candidate lists what is new, fixed and faster since the tag before it, each under its part" {
  commit 'feat(shell): a bar'
  git tag v1.0.0-rc.1
  commit 'fix(update): a backup that cannot be made stops the update'
  commit 'refactor(cli): two commands nothing called are gone'
  commit 'feat(installer): the install is one screen (with a bar)'
  commit 'perf: the tests run side by side'
  commit 'docs(images): the pictures taken again'
  commit 'feat!: a change that breaks'
  git tag v1.0.0-rc.2
  run notes v1.0.0-rc.2
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = '## What changed since v1.0.0-rc.1' ]
  [ "${lines[1]}" = '### New' ]
  [ "${lines[2]}" = '- **installer:** the install is one screen (with a bar)' ]
  [ "${lines[3]}" = '- a change that breaks' ]
  [ "${lines[4]}" = '### Fixed' ]
  [ "${lines[5]}" = '- **update:** a backup that cannot be made stops the update' ]
  [ "${lines[6]}" = '### Faster' ]
  [ "${lines[7]}" = '- the tests run side by side' ]
  [ "${lines[8]}" = '[Every commit since v1.0.0-rc.1](https://github.com/someone/nova/compare/v1.0.0-rc.1...v1.0.0-rc.2)' ]
  [[ $output != *"two commands"* && $output != *"pictures"* ]]
}

@test "a final release is compared with the final one before it, not with its own candidates" {
  commit 'feat(shell): a bar'
  git tag v1.0.0-rc.1
  git tag v1.0.0
  commit 'fix(lock): the first'
  git tag v1.0.1-rc.1
  commit 'fix(lock): the second'
  git tag v1.0.1-rc.2
  git tag v1.0.1
  run notes v1.0.1
  [ "${lines[0]}" = '## What changed since v1.0.0' ]
  [[ $output == *"the first"* && $output == *"the second"* ]]
  [[ $output == *"/compare/v1.0.0...v1.0.1)"* ]]
  # The candidate after a final release is compared with it under its final name.
  run notes v1.0.1-rc.1
  [ "${lines[0]}" = '## What changed since v1.0.0' ]
  run notes v1.0.1-rc.2
  [ "${lines[0]}" = '## What changed since v1.0.1-rc.1' ]
  [[ $output != *"the first"* ]]
}

@test "a release with nothing a person would notice says so, and still links every commit" {
  commit 'feat(shell): a bar'
  git tag v1.0.0
  commit 'test(lock): one more'
  git tag v1.0.1-rc.1
  run notes v1.0.1-rc.1
  [[ $output == *"Nothing a person using Nova would notice."* ]]
  [[ $output == *"/compare/v1.0.0...v1.0.1-rc.1)"* ]]
}

@test "a tag that does not exist, or no address, is an error" {
  commit 'feat(shell): a bar'
  run notes v9.9.9
  [ "$status" -eq 1 ]
  run "$REPO_ROOT/tools/release-notes" v9.9.9
  [ "$status" -eq 2 ]
}
