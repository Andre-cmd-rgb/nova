-- What the session starts, in order, once Hyprland is up.
hl.on("hyprland.start", function()
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
