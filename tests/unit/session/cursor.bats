#!/usr/bin/env bats

# data/hypr/cursor.lua: the cursor theme the session names, Nova's or one the
# user chose, against a stand-in for Hyprland's Lua API that prints what the
# config asks for, with icon folders of the test's own.

load ../test_helper

setup() {
  setup_scratch
  mkdir -p "$SCRATCH/nova/default" "$SCRATCH/home"
  ln -s "$REPO_ROOT/data/hypr" "$SCRATCH/nova/default/hypr"
  SHARE=$SCRATCH/share
  # Nova's theme, as make install puts it.
  write_file "$SHARE/icons/Nova/cursors/default" 'cursor'
  write_file "$SHARE/icons/Nova/manifest.hl" 'name = Nova'
  write_file "$SHARE/icons/Nova/index.theme" '[Icon Theme]'
}

teardown() { teardown_scratch; }

# The module, loaded as env.lua loads it, in an environment of only what is
# given.
cursor() { # NAME=value...
  env -i HOME="$SCRATCH/home" NOVA_PATH="$SCRATCH/nova" XDG_DATA_DIRS="$SHARE" "$@" lua -e '
    local function show(v)
      if type(v) ~= "table" then return tostring(v) end
      local keys = {}
      for k in pairs(v) do keys[#keys + 1] = k end
      table.sort(keys)
      local parts = {}
      for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. show(v[k]) end
      return "{" .. table.concat(parts, ",") .. "}"
    end
    hl = setmetatable({}, { __index = function(_, name)
      return function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[#parts + 1] = show((select(i, ...))) end
        print(name .. " " .. table.concat(parts, " "))
      end
    end })
    dofile(os.getenv("NOVA_PATH") .. "/default/hypr/bootstrap.lua")
    require("default.hypr.cursor")' </dev/null
}

own_default() { # theme
  write_file "$SCRATCH/home/.local/share/icons/default/index.theme" "[Icon Theme]
Inherits=$1"
}

@test "Nova's theme in both forms, where nothing else was chosen" {
  run cursor
  [ "$status" -eq 0 ]
  [ "$output" = $'env XCURSOR_THEME Nova\nenv HYPRCURSOR_THEME Nova' ]
}

@test "env.lua names the theme, after the cursor's size" {
  run grep -n -e XCURSOR_SIZE -e 'default.hypr.cursor' "$REPO_ROOT/data/hypr/env.lua"
  [ "${#lines[@]}" -eq 2 ]
  [[ ${lines[1]} == *'require("default.hypr.cursor")'* ]]
}

@test "your own default theme wins, drawn by Hyprland as XCursor when it has no Hyprcursor form" {
  own_default Bibata-Modern-Ice
  write_file "$SHARE/icons/Bibata-Modern-Ice/cursors/default" 'cursor'
  run cursor
  [ "$status" -eq 0 ]
  [ "$output" = $'env XCURSOR_THEME default\nconfig {cursor={enable_hyprcursor=false}}' ]
}

@test "your own default theme's Hyprcursor form is the one Hyprland draws" {
  own_default Mine
  write_file "$SCRATCH/home/.local/share/icons/Mine/manifest.hl" 'name = Mine'
  run cursor
  [ "$output" = $'env XCURSOR_THEME default\nenv HYPRCURSOR_THEME Mine' ]
}

@test "a default theme in ~/.icons, as nwg-look writes it, is yours too" {
  write_file "$SCRATCH/home/.icons/default/index.theme" $'[Icon Theme]\nInherits = Adwaita, hicolor'
  run cursor
  [ "$output" = $'env XCURSOR_THEME default\nconfig {cursor={enable_hyprcursor=false}}' ]
}

@test "a default theme that inherits Nova's gets Nova's Hyprcursor form" {
  own_default Nova
  run cursor
  [ "$output" = $'env XCURSOR_THEME default\nenv HYPRCURSOR_THEME Nova' ]
}

@test "an XCURSOR_THEME the session started with is kept" {
  run cursor XCURSOR_THEME=Bibata
  [ "$output" = 'config {cursor={enable_hyprcursor=false}}' ]
  write_file "$SHARE/icons/Bibata/manifest.toml" '[General]'
  run cursor XCURSOR_THEME=Bibata
  [ "$output" = 'env HYPRCURSOR_THEME Bibata' ]
}

@test "a HYPRCURSOR_THEME the session started with is kept" {
  run cursor HYPRCURSOR_THEME=Mine
  [ "$output" = 'env XCURSOR_THEME Nova' ]
}

@test "on a reload, what the config set before is decided again" {
  own_default Bibata
  run cursor XCURSOR_THEME=Nova HYPRCURSOR_THEME=Nova
  [ "$output" = $'env XCURSOR_THEME default\nconfig {cursor={enable_hyprcursor=false}}' ]
}

@test "without Nova's theme installed, nothing is named" {
  rm -r "$SHARE/icons/Nova"
  run cursor
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the greeter names Nova's theme too" {
  grep -qx 'hl.env("XCURSOR_THEME", "Nova")' "$REPO_ROOT/data/session/greeter/greeter-hyprland.lua"
  grep -qx 'hl.env("HYPRCURSOR_THEME", "Nova")' "$REPO_ROOT/data/session/greeter/greeter-hyprland.lua"
}
