-- What the session starts, in order, once Hyprland is up.

-- X11 programs draw at the displays' resolution and scale themselves
-- (env.lua). Most read the scale from the X server, which
-- nova-hyprland-x11-scale tells (the monitor watch runs it); Java reads only
-- its environment, J2D_UISCALE, a whole number. It is the X11 scale of the
-- displays the session came up with, which Settings → Displays and
-- monitors.lua decide, chosen as nova-hyprland-x11-scale chooses it: with
-- Nova's Hyprland, which shrinks X11 windows on displays of a lower scale
-- (xwayland.scale, set here too, before anything starts), the largest
-- display's rounded up; with another, the built-in panel's while it is on,
-- else the largest, to the nearest; or NOVA_X11_SCALE. J2D_UISCALE is set only
-- from 2 up, as 1 is Java's own, and not over a J2D_UISCALE of yours: Java
-- takes it first. A GDK_SCALE of yours leaves both alone. The displays are up
-- by the first frame, which is when this runs.
local function x11_scale()
  if (os.getenv("GDK_SCALE") or "") ~= "" then return end
  local shrinks = hl.get_config("xwayland.scale") ~= nil
  local whole = tonumber((os.getenv("NOVA_X11_SCALE") or ""):match("^[1-9]$"))
  if not whole then
    local panel, largest
    for _, monitor in ipairs(hl.get_monitors()) do
      local scale = tonumber(monitor.scale)
      if monitor.enabled ~= false and scale then
        local name = monitor.name or ""
        if name:match("^eDP%-") or name:match("^LVDS%-") or name:match("^DSI%-") then panel = scale end
        if not largest or scale > largest then largest = scale end
      end
    end
    if shrinks then
      -- Hyprland's scales are floats (1.6 is 1.600000023841858): rounded up
      -- from hundredths, so a scale a hair over a whole number is that number.
      whole = math.max(1, math.ceil(math.floor((largest or 1) * 100 + 0.5) / 100))
    else
      whole = math.max(1, math.floor((panel or largest or 1) + 0.5))
    end
  end
  if shrinks then hl.config({ xwayland = { scale = whole } }) end
  if whole >= 2 and (os.getenv("J2D_UISCALE") or "") == "" then hl.env("J2D_UISCALE", tostring(whole)) end
end

hl.on("hyprland.start", function()
  -- First, so all that follows has it; a failure here must not cost the shell.
  pcall(x11_scale)

  -- Programs that systemd and D-Bus start (every app, through uwsm-app) get
  -- the session's environment: its PATH, with Nova's commands, and the rest
  -- of env.lua.
  hl.exec_cmd("systemctl --user import-environment $(env | cut -d'=' -f 1)")
  hl.exec_cmd("dbus-update-activation-environment --systemd --all")

  -- The theme rendered and applied again first if an update of Nova changed
  -- what it is made from (nova-theme refresh, a moment's look otherwise),
  -- so that the shell starts in it.
  hl.exec_cmd("nova-theme refresh; exec nova-launch-shell")
  -- Caffeine left on without its lid lock (by a user manager that restarted)
  -- is turned off.
  hl.exec_cmd("nova-caffeine reconcile")
  -- Chrome's Energy Saver on whenever unplugged, set once per profile while
  -- Chrome cannot be open yet; after that it is Chrome's own setting.
  hl.exec_cmd("nova-chrome-energy-saver")
  hl.exec_cmd(nova.launch("nova-hyprland-monitor-watch"))
  -- An app a crash takes away is named, with Reopen, as on a Mac.
  hl.exec_cmd(nova.launch("nova-crash-watch"))
  hl.exec_cmd("sleep 2 && nova-hook post-boot")
end)
