-- Nova Hyprland setup: helpers, defaults, and current theme overrides.

require("default.hypr.helpers")
local require_optional = require("default.hypr.require_optional")

-- Use Nova defaults, but don't edit these directly.
require("default.hypr.session")
require("default.hypr.autostart")
if _G.nova_default_bindings ~= false then
  require("default.hypr.bindings.media")
  require("default.hypr.bindings.clipboard")
  require("default.hypr.bindings.tiling")
  require("default.hypr.bindings.utilities")
  require_optional.module("default.hypr.bindings.applications")
end
require("default.hypr.envs")
require("default.hypr.looknfeel")
require("default.hypr.input")
require("default.hypr.windows")

-- Current theme overrides.
require_optional.module("nova.current.theme.hyprland")
