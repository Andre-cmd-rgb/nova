-- Nova's Hyprland defaults, required by ~/.config/hypr/hyprland.lua before your
-- own modules. Updates change these; your files stay as you left them.

require("default.hypr.lib")

require("default.hypr.session")
require("default.hypr.autostart")

if nova_default_bindings ~= false then
  require("default.hypr.keys.media")
  require("default.hypr.keys.clipboard")
  require("default.hypr.keys.windows")
  require("default.hypr.keys.desktop")
  require("default.hypr.keys.dictation")
  require("default.hypr.keys.apps")
end

require("default.hypr.env")
require("default.hypr.look")
require("default.hypr.behavior")
require("default.hypr.input")
require("default.hypr.rules")

-- The theme's borders, last, so a theme wins over the defaults above.
nova.run_if_present(nova.state .. "/current/theme/hyprland.lua")
