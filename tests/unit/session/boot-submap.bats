#!/usr/bin/env bats

# data/hypr/session.lua against a stand-in for Hyprland's Lua API that keeps
# Hyprland 0.56's rule: a submap exists once a bind is made in it, and
# switching to one that does not is an error.

load ../test_helper

start() { # NOVA_LOGIN: runs session.lua, then its start hooks; prints the submap
  NOVA_LOGIN=$1 SESSION="$REPO_ROOT/data/hypr/session.lua" lua -e '
    local submaps, defining, current, hooks = {}, nil, "default", {}
    hl = {
      define_submap = function(name, body) defining = name; body(); defining = nil end,
      bind = function() if defining then submaps[defining] = true end end,
      on = function(event, fn) if event == "hyprland.start" then hooks[#hooks + 1] = fn end end,
      dsp = { submap = function(name) return name end },
      dispatch = function(name)
        if name ~= "reset" and not submaps[name] then error("Cannot set submap " .. name .. ", submap doesn'"'"'t exist") end
        current = name
      end,
    }
    dofile(os.getenv("SESSION"))
    for _, fn in ipairs(hooks) do fn() end
    io.write(current)' </dev/null
}

@test "an autologin session starts in the boot submap" {
  run start autologin
  [ "$status" -eq 0 ]
  [ "$output" = "nova-boot" ]
}

@test "a session with no NOVA_LOGIN starts in the boot submap" {
  run start ""
  [ "$status" -eq 0 ]
  [ "$output" = "nova-boot" ]
}

@test "a session after a password check starts with every bind" {
  run start password
  [ "$status" -eq 0 ]
  [ "$output" = "default" ]
}
