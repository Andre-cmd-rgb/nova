#!/usr/bin/env bats

# No program of Nova's puts a command in a notification's hints: any program
# on the session bus may send hints, a sandboxed app's too, so the shell runs
# only what a file in Nova's runtime folder says, which the nova-command hint
# names (src/shell/plugins/notifications/components/Commands.qml). A sender
# that went back to the hints that once carried one would send buttons that
# do nothing; this says so before anyone clicks.

load ../test_helper

@test "no source sends a command in a notification's hints" {
  # Code only: a README may name the hints that once carried a command.
  run git -C "$REPO_ROOT" grep -n -E 'nova-(exec-argv|buttons)' -- src data installer tools ':(exclude)*/tests/*' ':(exclude)*.md'
  [ "$status" -eq 1 ] || {
    printf '%s\n' "$output"
    false
  }
}

# Two programs write such files, Nova's sender and the iPhone daemon, and the
# shell reads them: one more is a new way in, to be looked at as such.
@test "the commands' files are written in two places, and read in one" {
  # Code only, no comment or README: a line that names the hint before any # or /.
  run git -C "$REPO_ROOT" grep -l -E '^[^#/]*nova-command' -- src ':(exclude)*/tests/*' ':(exclude)*.md'
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | sort | paste -sd ' ')" = 'src/cli/bin/nova-notification-send src/iphone/daemon/src/service.rs src/shell/plugins/notifications/NotificationLogic.js' ]
}
