-- Settings switched from the menu, Settings and the keys, kept as files in
-- Nova's state ($XDG_STATE_HOME/nova, ~/.local/state/nova by default). ~/.config/hypr/hyprland.lua loads this last, so they
-- win over your own settings too.

require("default.hypr.lib")

local toggles = nova.state .. "/toggles/hypr"
local layouts = nova.state .. "/workspace-layouts"
local files = nova.lua_files({ toggles, layouts })

-- A toggle that is on is a file: a copy of one in default/hypr/toggles
-- (nova-hyprland-toggle), or one a tool wrote, the displays (nova monitor)
-- or the laptop screen off.
for _, path in ipairs(files[toggles]) do dofile(path) end

-- The touchpad turned off (nova-toggle-touchpad). Its name comes from the
-- device, so it is kept as text, never run as Lua.
local touchpad = io.open(toggles .. "/touchpad-disabled-name")
if touchpad then
  local name = touchpad:read("l")
  touchpad:close()
  if name and name ~= "" then hl.device({ name = name, enabled = false }) end
end

-- Each workspace switched to the other layout (SUPER + L).
for _, path in ipairs(files[layouts]) do dofile(path) end
