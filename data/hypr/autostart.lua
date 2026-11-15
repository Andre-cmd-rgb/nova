-- What the session starts, in order, once Hyprland is up.

-- X11 programs draw at 1x and scale themselves (env.lua), GTK's and Java's by
-- GDK_SCALE, a whole number. Unless the session has one already (your
-- monitors.lua, or the environment it started in), it is the scale the
-- displays came up at, which Settings → Displays and monitors.lua decide: the
-- built-in panel's while it is on, else the largest. Rounded, as
-- nova-hyprland-monitor-scaling rounds it, and set only from 2 up: 1 is GTK's
-- own. The displays are up by the first frame, which is when this runs.
local function x11_scale()
  if (os.getenv("GDK_SCALE") or "") ~= "" then return end
  local panel, largest
  for _, monitor in ipairs(hl.get_monitors()) do
    local scale = tonumber(monitor.scale)
    if monitor.enabled ~= false and scale then
      local name = monitor.name or ""
      if name:match("^eDP%-") or name:match("^LVDS%-") or name:match("^DSI%-") then panel = scale end
      if not largest or scale > largest then largest = scale end
    end
  end
  local whole = math.floor((panel or largest or 1) + 0.5)
  if whole >= 2 then hl.env("GDK_SCALE", tostring(whole)) end
end

hl.on("hyprland.start", function()
  -- First, so all that follows has it; a failure here must not cost the shell.
  pcall(x11_scale)

  -- Programs that systemd and D-Bus start (every app, through uwsm-app) get
  -- the session's environment: its PATH, with Nova's commands, and the rest
  -- of env.lua.
  hl.exec_cmd("systemctl --user import-environment $(env | cut -d'=' -f 1)")
  hl.exec_cmd("dbus-update-activation-environment --systemd --all")

  hl.exec_cmd("nova-launch-shell")
  -- Caffeine left on without its lid lock (by a user manager that restarted)
  -- is turned off.
  hl.exec_cmd("nova-caffeine reconcile")
  -- Chrome's Energy Saver on whenever unplugged, set once per profile while
  -- Chrome cannot be open yet; after that it is Chrome's own setting.
  hl.exec_cmd("nova-chrome-energy-saver")
  hl.exec_cmd(nova.launch("nova-hyprland-monitor-watch"))
  hl.exec_cmd("sleep 2 && nova-hook post-boot")
end)
