-- Restore workspace layouts saved by nova-hyprland-workspace-layout-toggle.

local paths = require("default.hypr.paths")
local require_all = require("default.hypr.require_all")

local layouts_dir = paths.state_home .. "/nova/workspace-layouts"

require_all.files(layouts_dir, "nova.workspace-layouts", { reload = true })
