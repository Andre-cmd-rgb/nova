-- See https://wiki.hypr.land/Configuring/Basics/Window-Rules/

o.window(".*", { suppress_event = "maximize" })

-- Tag all windows for default opacity (apps can override with -default-opacity tag).
o.window(".*", { tag = "+default-opacity" })

-- Fix some dragging issues with XWayland.
o.window(
  {
    class = "^$",
    title = "^$",
    xwayland = true,
    float = true,
    fullscreen = false,
    pin = false,
  },
  { no_focus = true }
)

-- App-specific tweaks (may remove default-opacity tag).
require("default.hypr.apps")

-- Apply default opacity after apps have had a chance to opt out.
o.window({ tag = "default-opacity" }, { opacity = "0.985 0.96" })

-- A hardware profile whose GPU is short of memory bandwidth (a Raspberry Pi's)
-- sets o.opaque_windows, and every window is opaque, the apps' own opacities
-- above too, as the last rule wins. Hyprland draws nothing under an opaque
-- window; under a see-through one it draws the wallpaper and every window
-- below it, each frame.
if o.opaque_windows then
  o.window(".*", { opacity = "1 1" })
end
