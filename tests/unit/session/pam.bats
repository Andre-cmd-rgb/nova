#!/usr/bin/env bats

# The fingerprint at the password prompts of polkit and sudo: the PAM and
# sudoers files that put it ahead of the password, and the lid check that skips
# the reader while it is out of reach.

load ../test_helper

PAM=$REPO_ROOT/data/session/pam.d
LID_OPEN=$REPO_ROOT/src/cli/bin/nova-hw-laptop-open
SUDOERS=$REPO_ROOT/data/session/sudoers.d/20-nova-pam

setup() {
  setup_scratch
  export NOVA_LID_PATH=$SCRATCH/lid
}

teardown() {
  teardown_scratch
}

# The PAM lines of a file, comments and blank lines dropped, each line's
# columns joined by one space.
pam_lines() { sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "$1" | tr -s ' \t' ' '; }

@test "the lid check says no only for a shut lid, so PAM skips the reader then" {
  write_file "$NOVA_LID_PATH/LID/state" 'state:      open'
  run "$LID_OPEN"
  [ "$status" -eq 0 ]
  write_file "$NOVA_LID_PATH/LID/state" 'state:      closed'
  run "$LID_OPEN"
  [ "$status" -ne 0 ]
}

@test "without a lid, a desktop's, the reader stays in" {
  run "$LID_OPEN"
  [ "$status" -eq 0 ]
}

@test "the lid check's jump lands past the fingerprint, on the password" {
  local f
  for f in polkit-1 nova-sudo; do
    run pam_lines "$PAM/$f"
    [ "${lines[0]}" = "auth [success=ignore default=1] pam_exec.so quiet /usr/lib/nova/bin/nova-hw-laptop-open" ]
    [ "${lines[1]}" = "-auth sufficient pam_fprintd.so timeout=15" ]
    [[ ${lines[2]} == "auth include "* ]]
  done
}

@test "polkit-1 runs polkit's own stack after the fingerprint" {
  [[ -f /usr/lib/pam.d/polkit-1 ]] || skip "polkit is not installed"
  diff <(pam_lines "$PAM/polkit-1" | tail -n +3) <(pam_lines /usr/lib/pam.d/polkit-1)
}

@test "nova-sudo runs sudo's own stack after the fingerprint" {
  run pam_lines "$PAM/nova-sudo"
  [ "${lines[2]}" = "auth include sudo" ]
  [ "${lines[3]}" = "account include sudo" ]
  [ "${lines[4]}" = "session include sudo" ]
  [ "${#lines[@]}" -eq 5 ]
}

@test "the sudoers drop-in parses, and names the PAM service Nova ships" {
  command -v visudo >/dev/null || skip "sudo is not installed"
  visudo -cqf "$SUDOERS"
  grep -qx 'Defaults pam_service=nova-sudo, pam_login_service=nova-sudo' "$SUDOERS"
  [ -f "$PAM/nova-sudo" ]
}

@test "the drop-in's name has no dot, or sudo would skip it" {
  [[ $(basename "$SUDOERS") != *.* && $(basename "$SUDOERS") != *~ ]]
}
