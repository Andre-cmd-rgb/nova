-- Your Hyprland configuration. https://wiki.hypr.land/Configuring/Start/

-- Nova's bootstrap sets up where modules come from: your files in ~/.config,
-- Nova's defaults in /usr/share/nova.
dofile((os.getenv("NOVA_PATH") or "/usr/share/nova") .. "/default/hypr/bootstrap.lua")

-- To start from no key bindings at all and define every one in
-- hypr/bindings.lua, uncomment this:
-- nova_default_bindings = false

-- Nova's defaults. Updates improve these without touching your files.
require("default.hypr.nova")

-- Your changes, loaded after the defaults so they win.
require("hypr.monitors")
require("hypr.input")
require("hypr.bindings")
require("hypr.looknfeel")
require("hypr.autostart")

-- Settings switched from the menu (window gaps and the like).
require("default.hypr.toggles")
