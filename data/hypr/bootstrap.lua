-- Run first by ~/.config/hypr/hyprland.lua: where the config's modules come
-- from. Yours (hypr.*) are in ~/.config, Nova's (default.hypr.*) in NOVA_PATH,
-- both ahead of Lua's own path. Hyprland starts each load of the config in a
-- new Lua state, so this runs on a clean slate every time.

local nova_path = os.getenv("NOVA_PATH")
if nova_path == nil or nova_path == "" then nova_path = "/usr/share/nova" end
package.path = os.getenv("HOME") .. "/.config/?.lua;" .. nova_path .. "/?.lua;" .. package.path
