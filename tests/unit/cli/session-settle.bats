#!/usr/bin/env bats

# nova-session-settle, which nova update runs once a release is in: the
# session's services moved onto it. systemctl is a stub that lists
# $SCRATCH/units and $SCRATCH/scopes, shows what $SCRATCH/props/<unit>/<name>
# holds (or a unit that is there and has run), and logs everything else.

load ../test_helper

setup() {
  setup_scratch
  export CALLS="$SCRATCH/calls" NOVA_SESSION_WANTS="$SCRATCH/wants"
  mkdir -p "$SCRATCH/bin" "$SCRATCH/props" "$NOVA_SESSION_WANTS"
  : >"$SCRATCH/units"
  : >"$SCRATCH/scopes"
  : >"$SCRATCH/graphical"
  echo HYPRLAND_INSTANCE_SIGNATURE=this-session >"$SCRATCH/environment"
  cat >"$SCRATCH/bin/systemctl" <<'EOF'
#!/bin/bash
all="$*"
[[ $1 == --user ]] && shift
case $1 in
  list-units)
    if [[ " $* " == *" --type=scope "* ]]; then cat "$SCRATCH/scopes"; else cat "$SCRATCH/units"; fi ;;
  show)
    prop=${2#--property=} unit=${*: -1}
    if [[ -e $SCRATCH/props/$unit/$prop ]]; then cat "$SCRATCH/props/$unit/$prop"; else
      case $prop in LoadState) echo loaded ;; FreezerState) echo running ;; *) echo 1 ;; esac
    fi ;;
  show-environment) cat "$SCRATCH/environment" ;;
  --quiet) [[ -e $SCRATCH/graphical ]] ;;
  *)
    echo "systemctl $all" >>"$CALLS"
    [[ $1 != start || ! -e $SCRATCH/start-fails ]] ;;
esac
EOF
  chmod +x "$SCRATCH/bin/systemctl"
  export PATH="$SCRATCH/bin:$PATH"
}

teardown() { teardown_scratch; }

settle() { "$REPO_ROOT/src/cli/bin/nova-session-settle"; }
prop() { mkdir -p "$SCRATCH/props/$1" && echo "$3" >"$SCRATCH/props/$1/$2"; }
# A unit file, and its link in graphical-session.target.wants.
wanted() { touch "$SCRATCH/$1" && ln -s "../$1" "$NOVA_SESSION_WANTS/$1"; }

@test "Nova's units whose files are gone are stopped and their failure forgotten; the rest are left" {
  cat >"$SCRATCH/units" <<'EOF'
nova-idle-inhibitors.service not-found active running nova-idle-inhibitors.service
nova-went-wrong.service not-found failed failed nova-went-wrong.service
nova-long-gone.service not-found inactive dead nova-long-gone.service
nova-kept.service loaded active running Something Nova still has
pulseaudio.service not-found active running pulseaudio.service
EOF
  run settle
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS")" = "$(printf '%s\n' \
    'systemctl --user daemon-reload' \
    'systemctl --user stop -- nova-idle-inhibitors.service' \
    'systemctl --user reset-failed -- nova-idle-inhibitors.service' \
    'systemctl --user reset-failed -- nova-went-wrong.service')" ]
  [[ $output == *"Stopping nova-idle-inhibitors.service: this release has none."* ]]
}

@test "a frozen one is killed as it is, before a stop would thaw it" {
  echo 'nova-automount.service not-found active running nova-automount.service' >"$SCRATCH/units"
  prop nova-automount.service FreezerState frozen
  run settle
  [ "$status" -eq 0 ]
  [ "$(grep -v daemon-reload "$CALLS")" = "$(printf '%s\n' \
    'systemctl --user kill --signal=SIGKILL -- nova-automount.service' \
    'systemctl --user stop -- nova-automount.service' \
    'systemctl --user reset-failed -- nova-automount.service')" ]
}

@test "the old automounter stopped, its successor knows this session's drives were looked at" {
  echo 'nova-automount.service not-found active running nova-automount.service' >"$SCRATCH/units"
  run settle
  [ "$status" -eq 0 ]
  [ "$(cat "$XDG_RUNTIME_DIR/nova/automount-swept")" = this-session ]
  [ "$(stat -c %a "$XDG_RUNTIME_DIR/nova")" = 700 ]
}

@test "with no Hyprland in the session's environment, nothing is marked" {
  : >"$SCRATCH/environment"
  echo 'nova-automount.service not-found active running nova-automount.service' >"$SCRATCH/units"
  run settle
  [ "$status" -eq 0 ]
  [ ! -e "$XDG_RUNTIME_DIR/nova/automount-swept" ]
  grep -qx 'systemctl --user stop -- nova-automount.service' "$CALLS"
}

@test "an earlier release's autostarted helpers are stopped; apps, even one a launcher started, are not" {
  cat >"$SCRATCH/scopes" <<'EOF'
app-Hyprland-nova\x2dcrash\x2dwatch-7bde32ae.scope loaded active running nova-crash-watch
app-Hyprland-nova\x2dhyprland\x2dmonitor\x2dwatch-9e834d87.scope loaded active running nova-hyprland-monitor-watch
app-Hyprland-nova\x2dlaunch\x2deditor-11111111.scope loaded active running nova-launch-editor
app-Hyprland-foot-22222222.scope loaded active running foot
app-Hyprland-nova\x2dcrash\x2dwatch-33333333.scope loaded inactive dead nova-crash-watch
EOF
  run settle
  [ "$status" -eq 0 ]
  [ "$(grep -c '^systemctl --user stop' "$CALLS")" = 2 ]
  grep -qxF 'systemctl --user stop -- app-Hyprland-nova\x2dcrash\x2dwatch-7bde32ae.scope' "$CALLS"
  grep -qxF 'systemctl --user stop -- app-Hyprland-nova\x2dhyprland\x2dmonitor\x2dwatch-9e834d87.scope' "$CALLS"
  [[ $output == *"Stopping nova-crash-watch: this release has none."* ]]
}

@test "units every session starts are started if they never have been in this one" {
  wanted nova-sessiond.service
  prop nova-sessiond.service InactiveExitTimestampMonotonic 0
  prop nova-sessiond.service ConditionTimestampMonotonic 0
  # Ran, or was stopped, at some point: left as it is.
  wanted nova-session-guard.service
  # Its conditions said no at the login: not asked again.
  wanted nova-conditional.service
  prop nova-conditional.service InactiveExitTimestampMonotonic 0
  # Masked by the user.
  wanted nova-masked.service
  prop nova-masked.service LoadState masked
  prop nova-masked.service InactiveExitTimestampMonotonic 0
  prop nova-masked.service ConditionTimestampMonotonic 0
  # Not Nova's.
  wanted other.service
  prop other.service InactiveExitTimestampMonotonic 0
  prop other.service ConditionTimestampMonotonic 0
  run settle
  [ "$status" -eq 0 ]
  [ "$(grep -v daemon-reload "$CALLS")" = 'systemctl --user start --no-block -- nova-sessiond.service' ]
  [[ $output == *"Starting nova-sessiond.service, which this release brings."* ]]
}

@test "the gone are stopped before the new start" {
  echo 'nova-sleep-lock.service not-found active running nova-sleep-lock.service' >"$SCRATCH/units"
  wanted nova-sessiond.service
  prop nova-sessiond.service InactiveExitTimestampMonotonic 0
  prop nova-sessiond.service ConditionTimestampMonotonic 0
  run settle
  [ "$status" -eq 0 ]
  [ "$(grep -oE '^systemctl --user (stop|start)' "$CALLS" | paste -sd' ')" = "systemctl --user stop systemctl --user start" ]
}

@test "outside a graphical session nothing is started, and the gone are stopped all the same" {
  rm "$SCRATCH/graphical"
  echo 'nova-sleep-lock.service not-found active running nova-sleep-lock.service' >"$SCRATCH/units"
  wanted nova-sessiond.service
  prop nova-sessiond.service InactiveExitTimestampMonotonic 0
  prop nova-sessiond.service ConditionTimestampMonotonic 0
  run settle
  [ "$status" -eq 0 ]
  grep -qx 'systemctl --user stop -- nova-sleep-lock.service' "$CALLS"
  fails grep -q start "$CALLS"
}

@test "a unit that will not start is said, and is no failure" {
  touch "$SCRATCH/start-fails"
  wanted nova-sessiond.service
  prop nova-sessiond.service InactiveExitTimestampMonotonic 0
  prop nova-sessiond.service ConditionTimestampMonotonic 0
  run settle
  [ "$status" -eq 0 ]
  [[ $output == *"nova-sessiond.service did not start; it will at the next login"* ]]
}
