#!/usr/bin/env bats

# The order the user manager starts the session's units in, as systemd itself
# works it out: `systemd --test --user` builds the start-up transaction from a
# folder of units and prints it, starting nothing. The units are Nova's own;
# the targets around them are stand-ins.

load ../test_helper

setup() {
  setup_scratch
  if [[ ! -x /usr/lib/systemd/systemd ]]; then
    [[ -z ${NOVA_REQUIRE_SYSTEMD_TEST:-} ]] || return 1
    skip "needs systemd"
  fi
  units=$SCRATCH/units
  mkdir -p "$units/graphical-session.target.wants" "$units/app-.service.d" "$SCRATCH/run"
  chmod 700 "$SCRATCH/run"
  cp "$REPO_ROOT/data/session/systemd/nova-session-guard.service" "$units/"
  ln -s ../nova-session-guard.service "$units/graphical-session.target.wants/"
  cp "$REPO_ROOT"/data/systemd/user/app-.service.d/*.conf "$units/app-.service.d/"
  for target in graphical-session.target graphical-session-pre.target basic.target default.target shutdown.target; do
    printf '[Unit]\nDescription=%s\n' "$target" >"$units/$target"
  done
  # What systemd-xdg-autostart-generator makes of an autostart entry.
  printf '[Unit]\nDescription=an autostart app\nPartOf=graphical-session.target\nAfter=graphical-session.target\n[Service]\nExecStart=/bin/true\n' \
    >"$units/app-chat@autostart.service"
}

teardown() { teardown_scratch; }

# Sets $ordering to how systemd orders <unit> towards <other> ("After:",
# "Before:", or nothing) in the transaction that starts <unit>.
ordering_of() { # unit other
  local transaction
  if ! transaction=$(env -i HOME="$SCRATCH" XDG_RUNTIME_DIR="$SCRATCH/run" SYSTEMD_UNIT_PATH="$units" \
    timeout 30 /usr/lib/systemd/systemd --test --user --unit="$1" --no-pager 2>"$SCRATCH/systemd.log") ||
    [[ $transaction != *"Unit $1:"* ]]; then
    # CI asks for the check (NOVA_REQUIRE_SYSTEMD_TEST): there a skip would
    # pass it unseen.
    if [[ -n ${NOVA_REQUIRE_SYSTEMD_TEST:-} ]]; then
      cat "$SCRATCH/systemd.log"
      return 1
    fi
    skip "systemd cannot make a test run here, or prints it differently"
  fi
  # systemd breaks a cycle by dropping a job and says so; the orderings stay
  # in what it prints.
  if grep -i 'ordering cycle' "$SCRATCH/systemd.log"; then return 1; fi
  # A unit's block starts with a tab, an arrow and "Unit <name>:"; its orderings
  # are indented by two tabs.
  ordering=$(awk -v unit="$1" -v other="$2" '
    $2 == "Unit" && NF == 3 { here = ($3 == unit ":") }
    here && /^\t\t(After|Before): / && $2 == other { print $1 }' <<<"$transaction")
}

@test "the session's target does not wait for the lock: the desktop portal, ordered after it, starts at once" {
  # A target waits for a oneshot it wants unless told otherwise, and the guard
  # is done only when the lock is secure; a shell that asked the portal as it
  # started then waited on the guard, which waited on the shell.
  ordering_of graphical-session.target nova-session-guard.service
  [ -z "$ordering" ]
}

@test "the guard starts with the session, not once every unit the session wants has started" {
  ordering_of nova-session-guard.service graphical-session.target
  [ -z "$ordering" ]
  ordering_of nova-session-guard.service graphical-session-pre.target
  [ "$ordering" = "After:" ]
}

@test "an autostart app waits for the lock, so that no window shows before it on an autologin boot" {
  ordering_of app-chat@autostart.service nova-session-guard.service
  [ "$ordering" = "After:" ]
}
