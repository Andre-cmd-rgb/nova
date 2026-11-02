-- Settings switched from the menu, Settings and the keys, kept as files in
-- ~/.local/state/nova. ~/.config/hypr/hyprland.lua loads this last, so they
-- win over your own settings too.

require("default.hypr.lib")

local toggles = nova.state .. "/toggles/hypr"
local layouts = nova.state .. "/workspace-layouts"
local files = nova.lua_files({ toggles, layouts })

-- A toggle that is on is a file: a copy of one in default/hypr/toggles
-- (nova-hyprland-toggle), or one a tool wrote, the displays (nova monitor)
-- or the laptop screen off.
for _, path in ipairs(files[toggles]) do dofile(path) end

-- An input device turned off (nova-toggle-input-device). Its name comes from
-- the device, so it is kept as text, never run as Lua.
for _, kind in ipairs({ "touchpad", "touchscreen" }) do
  local file = io.open(toggles .. "/" .. kind .. "-disabled-name")
  if file then
    local name = file:read("l")
    file:close()
    if name and name ~= "" then hl.device({ name = name, enabled = false }) end
  end
end

-- Each workspace switched to the other layout (SUPER + L).
for _, path in ipairs(files[layouts]) do dofile(path) end
