#!/usr/bin/env bats

# The binds that work on the lock screen (marked `locked`): each must start
# nothing that shows or waits behind the lock, a window, a menu or a panel,
# which would hold the keyboard there until the unlock. Volume, brightness,
# the media keys, the touchpad and the lid are right to work there, and their
# feedback is the OSD; the power button looks at the lock itself
# (nova-power-button). A new locked bind is one more line here, with why it
# opens nothing. Each is named whole, never by a wildcard, which would let a
# new shortcut or verb of the same name (the capture picker's nova:screenshot)
# through.

load ../test_helper

# What a locked bind may run, and why that opens nothing behind the lock.
SAFE=(
  # The shell's key service: volume, brightness, keyboard light, and the OSD.
  nova:volume-up nova:volume-down nova:volume-mute nova:volume-up-fine nova:volume-down-fine
  nova:brightness-up nova:brightness-down nova:brightness-max nova:brightness-min
  nova:brightness-up-fine nova:brightness-down-fine
  nova:keyboard-up nova:keyboard-down nova:keyboard-cycle
  'nova-audio-input-mute'           # the microphone, and the OSD
  'nova-audio-output-switch'        # the next speaker, and the OSD
  'nova-audio-source-switch'        # the media service's next player
  'nova-toggle-touchpad'            # the touchpad, and the OSD
  'nova-toggle-touchpad on'
  'nova-toggle-touchpad off'
  'nova-shell media next'           # the player the shell shows
  'nova-shell media previous'
  'nova-shell media playPause'
  'eject'                           # the tray of a drive
  'nova-caffeine close'             # the lid shut: locks, or sleeps
  'nova-caffeine open'              # the lid opened: the displays
  'nova-power-button press'         # opens nothing while locked: it asks the lock
)

# Every bind of data/hypr/keys/*.lua marked locked, a line each: its keys,
# then what it runs (a global shortcut as nova:<name>, or the command).
locked_binds() {
  HYPR=$REPO_ROOT/data/hypr lua -e '
    -- Anything else of hl: a value that can be indexed to any depth, and
    -- called for a plain table (a dispatcher, as nova.bind takes one).
    local anything
    anything = setmetatable({}, { __index = function() return anything end, __call = function() return {} end })
    hl = setmetatable({
      dsp = setmetatable({
        global = function(name) return { global = name } end,
        exec_cmd = function(command) return { command = command } end,
      }, { __index = function() return anything end }),
      bind = function(keys, dispatcher, opts)
        if opts and opts.locked then
          local global = type(dispatcher) == "table" and rawget(dispatcher, "global")
          local command = type(dispatcher) == "table" and rawget(dispatcher, "command")
          print(keys .. "\t" .. (global and ("nova:" .. global:gsub("^nova:", "")) or command or "?"))
        end
        return anything
      end,
    }, { __index = function() return anything end })
    dofile(os.getenv("HYPR") .. "/lib.lua")
    for file in io.popen("ls " .. os.getenv("HYPR") .. "/keys/*.lua"):lines() do dofile(file) end' </dev/null
}

@test "every locked bind runs something that opens nothing behind the lock" {
  local binds keys action pattern wrong=() count=0
  binds=$(locked_binds)
  while IFS=$'\t' read -r keys action; do
    count=$((count + 1))
    for pattern in "${SAFE[@]}"; do
      [[ $action == "$pattern" ]] && continue 2
    done
    wrong+=("$keys: $action")
  done <<<"$binds"
  [ "$count" -ge 30 ]
  [ "${#wrong[@]}" -eq 0 ] || { printf 'opens something behind the lock: %s\n' "${wrong[@]}"; false; }
}

@test "the system menu's own key does not work behind the lock" {
  local binds
  binds=$(locked_binds)
  fails grep -E 'nova-menu|nova-launch|nova-settings|nova-shell shell toggle' <<<"$binds"
}
