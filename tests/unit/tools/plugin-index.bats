#!/usr/bin/env bats

# tools/plugin-index: a bar widget shown only while another plugin is on
# (barWidget.shownWith, as Screen Time's) must name a plugin that has a
# service, the one it reads; the build refuses one that names anything else.

load ../test_helper

setup() {
  setup_scratch
  mkdir -p "$SCRATCH/plugins"
  cp -r "$REPO_ROOT/src/shell/plugins/screentime" "$SCRATCH/plugins/"
}

teardown() { teardown_scratch; }

@test "Nova's plugins index, with Screen Time's widget shown with Screen Time" {
  run "$REPO_ROOT/tools/plugin-index" "$REPO_ROOT/src/shell/plugins"
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.[] | select(.dir == "screentime") | .manifest.id]' <<<"$output")" = '["nova.screentime-today","nova.screentime"]' ]
}

@test "a widget shown with a plugin that does not exist fails the build" {
  sed -i 's/"shownWith": "nova.screentime"/"shownWith": "nova.nowhere"/' "$SCRATCH/plugins/screentime/Today.manifest.json"
  run "$REPO_ROOT/tools/plugin-index" "$SCRATCH/plugins"
  [ "$status" -ne 0 ]
  [[ $output == *"nova.screentime-today is shown with nova.nowhere, which is no plugin with a service"* ]]
}

@test "a widget shown with something other than an id fails the build" {
  sed -i 's/"shownWith": "nova.screentime"/"shownWith": true/' "$SCRATCH/plugins/screentime/Today.manifest.json"
  run "$REPO_ROOT/tools/plugin-index" "$SCRATCH/plugins"
  [ "$status" -ne 0 ]
  [[ $output == *"barWidget.shownWith is not a plugin id"* ]]
}
