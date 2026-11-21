-- The environment of everything the session starts. Variables are set with
-- hl.env: what `hyprctl setenv` sets never reaches what a key runs.

local gpu = require("default.hypr.gpu")

hl.env("XCURSOR_SIZE", "24")
hl.env("HYPRCURSOR_SIZE", "24")

-- Wayland for every toolkit that can draw on it, X11 through XWayland for the rest.
hl.env("GDK_BACKEND", "wayland,x11,*")
hl.env("QT_QPA_PLATFORM", "wayland;xcb")
hl.env("QT_QPA_PLATFORMTHEME", "gtk3")
-- Not GTK_USE_PORTAL, which nova-launch gives apps alone: with it, GTK 3 asks
-- the desktop portal for its settings as it starts and waits for the answer
-- with no time limit, and here it would reach the shell (Qt's GTK theme
-- starts GTK 3), which has to lock the screen at login whatever the portal
-- does. It once waited there on a portal that waited on the lock, and the
-- guard ended every autologin session (nova-session-guard.service).
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
-- display: on a hybrid laptop, Chromium shows black video otherwise. VA-API is
-- named NVIDIA's driver only where libva-nvidia-driver is installed: named one
-- that is not there, no program decodes video on any card, where otherwise
-- libva finds the driver of the card a program opens.
local function installed(path)
  local file = io.open(path)
  if file then file:close() end
  return file ~= nil
end

if gpu.gsp then
  hl.env("NVD_BACKEND", "direct")
  if gpu.nvidia_display then
    if installed("/usr/lib/dri/nvidia_drv_video.so") then hl.env("LIBVA_DRIVER_NAME", "nvidia") end
    hl.env("__GLX_VENDOR_LIBRARY_NAME", "nvidia")
  end
elseif gpu.legacy then
  hl.env("NVD_BACKEND", "egl")
  if gpu.nvidia_display then hl.env("__GLX_VENDOR_LIBRARY_NAME", "nvidia") end
end

-- This model's own settings, which may override any of the above.
require("default.hypr.hardware")

hl.config({
  -- X11 programs draw at the display's resolution and scale themselves (by
  -- what nova-hyprland-x11-scale tells the X server, and Java by J2D_UISCALE,
  -- set in autostart.lua), rather than being stretched blurry by Hyprland.
  xwayland = { force_zero_scaling = true },
  -- Hyprland is updated with Nova, so no news window of its own after one.
  ecosystem = { no_update_news = true },
})

-- Nova's Hyprland draws X11 windows at one scale on every display, shrunk on
-- those of a lower one (xwayland.scale), which nova-hyprland-x11-scale sets
-- and writes down: a reload keeps it, rather than putting each display's own
-- back until the next pass. Arch's Hyprland has no such option.
local x11_scale = io.open((os.getenv("XDG_RUNTIME_DIR") or "") .. "/nova/x11-scale")
if x11_scale then
  local scale = tonumber(x11_scale:read("l") or "")
  x11_scale:close()
  if scale and scale >= 1 and scale <= 9 and hl.get_config("xwayland.scale") ~= nil then
    hl.config({ xwayland = { scale = scale } })
  end
end
