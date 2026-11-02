-- SUPER + C, V and X copy, paste and cut in any window, a terminal too, and in
-- the shell's panels.

-- Presses mods + key in what has the focus, a window or a layer (a panel), and
-- lets go 50 ms later. Hyprland's send_shortcut can leave the key it sends held
-- and repeating (https://github.com/hyprwm/Hyprland/discussions/14099), so the
-- press and the release go separately. A virtual keyboard (wtype) would not
-- do: the SUPER still held down would join the shortcut.
local function tap(mods, key)
  hl.dispatch(hl.dsp.send_key_state({ mods = mods, key = key, state = "down" }))
  hl.timer(function()
    hl.dispatch(hl.dsp.send_key_state({ mods = mods, key = key, state = "up" }))
  end, { timeout = 50, type = "oneshot" })
end

-- Terminals carry the terminal tag (rules.lua); Hyprland reports a tag a rule
-- set with a trailing "*".
local function in_terminal()
  local window = hl.get_active_window()
  for _, tag in ipairs(window and window.tags or {}) do
    if tag == "terminal" or tag == "terminal*" then return true end
  end
  return false
end

-- A terminal takes Ctrl + C as an interrupt, so it gets the Insert shortcuts.
nova.bind("SUPER + C", "Universal copy", function()
  if in_terminal() then tap("CTRL", "Insert") else tap("CTRL", "C") end
end)
nova.bind("SUPER + V", "Universal paste", function()
  if in_terminal() then tap("SHIFT", "Insert") else tap("CTRL", "V") end
end)
nova.bind("SUPER + X", "Universal cut", function() tap("CTRL", "X") end)
nova.bind("SUPER + CTRL + V", "Clipboard manager", "nova-shell shell toggle nova.clipboard")
