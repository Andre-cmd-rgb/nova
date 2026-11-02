-- The environment of everything the session starts. Variables are set with
-- hl.env: what `hyprctl setenv` sets never reaches what a key runs.

local gpu = require("default.hypr.gpu")

hl.env("XCURSOR_SIZE", "24")
hl.env("HYPRCURSOR_SIZE", "24")

-- Wayland for every toolkit that can draw on it, X11 through XWayland for the rest.
hl.env("GDK_BACKEND", "wayland,x11,*")
hl.env("QT_QPA_PLATFORM", "wayland;xcb")
hl.env("QT_QPA_PLATFORMTHEME", "gtk3")
hl.env("MOZ_ENABLE_WAYLAND", "1")
hl.env("ELECTRON_OZONE_PLATFORM_HINT", "wayland")
hl.env("OZONE_PLATFORM", "wayland")
hl.env("XDG_SESSION_TYPE", "wayland")

-- xdg-desktop-portal picks Hyprland's own portal, the one that shares the
-- screen, by these.
hl.env("XDG_CURRENT_DESKTOP", "Hyprland")
hl.env("XDG_SESSION_DESKTOP", "Hyprland")

hl.env("XCOMPOSEFILE", nova.home .. "/.XCompose")
hl.env("NOVA_PATH", nova.path)

-- Nova's commands first on the PATH, and there once.
local bin = nova.lib .. "/bin"
local path = { bin }
for entry in (os.getenv("PATH") or "/usr/local/bin:/usr/bin"):gmatch("[^:]+") do
  if entry ~= bin then path[#path + 1] = entry end
end
hl.env("PATH", table.concat(path, ":"))

-- NVIDIA's video decoding talks to the card itself from Turing on, and
-- through EGL before. Decoding and GLX go to NVIDIA only when it drives the
-- display: on a hybrid laptop, Chromium shows black video otherwise.
if gpu.gsp then
  hl.env("NVD_BACKEND", "direct")
  if gpu.nvidia_display then
    hl.env("LIBVA_DRIVER_NAME", "nvidia")
    hl.env("__GLX_VENDOR_LIBRARY_NAME", "nvidia")
  end
elseif gpu.legacy then
  hl.env("NVD_BACKEND", "egl")
  if gpu.nvidia_display then hl.env("__GLX_VENDOR_LIBRARY_NAME", "nvidia") end
end

-- This model's own settings, which may override any of the above.
require("default.hypr.hardware")

hl.config({
  -- X11 programs draw at the display's resolution and scale themselves
  -- (GDK_SCALE), rather than being stretched blurry by Hyprland.
  xwayland = { force_zero_scaling = true },
  -- Hyprland is updated with Nova, so no news window of its own after one.
  ecosystem = { no_update_news = true },
})
