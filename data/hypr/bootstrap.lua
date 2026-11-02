-- Run first by ~/.config/hypr/hyprland.lua, at each load of the config:
-- where its modules come from, and a fresh start for them.

local home = os.getenv("HOME")
local nova_path = os.getenv("NOVA_PATH")
if nova_path == nil or nova_path == "" then nova_path = "/usr/share/nova" end

-- Hyprland keeps one Lua state from load to load, so a module required before
-- would come back as it was. Nova's defaults and your modules load afresh.
for name in pairs(package.loaded) do
  if name:find("^default%.hypr%.") or name:find("^hypr%.") then package.loaded[name] = nil end
end

-- Set by hyprland.lua after this, when it wants no default bindings; cleared
-- here, so a line taken out of it takes effect at the next reload.
nova_default_bindings = nil

-- Your modules (hypr.*) from ~/.config, then Nova's (default.hypr.*), ahead of
-- Lua's own path, and once, however many times the config loads.
local ours = home .. "/.config/?.lua;" .. nova_path .. "/?.lua;"
if package.path:sub(1, #ours) ~= ours then package.path = ours .. package.path end
