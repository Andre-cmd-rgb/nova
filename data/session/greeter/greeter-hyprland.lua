-- Hyprland configuration for the login greeter, started by nova-greeter-session as
-- the unprivileged `greeter` user. It does one thing: run the Quickshell greeter on
-- every output and leave when the greeter is done. No bindings, no animations.

hl.monitor({
  output = "",
  mode = "preferred",
  position = "auto",
  scale = "auto",
})

hl.config({
  general = {
    gaps_in = 0,
    gaps_out = 0,
    border_size = 0,
  },
  decoration = {
    rounding = 0,
    shadow = { enabled = false },
    blur = { enabled = false },
  },
  animations = { enabled = false },
  misc = {
    disable_hyprland_logo = true,
    disable_splash_rendering = true,
    force_default_wallpaper = 0,
    background_color = "rgb(000000)",
  },
  ecosystem = {
    no_update_news = true,
    no_donation_nag = true,
  },
})

-- The client runs the greeter, records how it ended and asks Hyprland to exit, which
-- hands the seat back to greetd.
hl.on("hyprland.start", function()
  hl.exec_cmd("/usr/lib/nova/bin/nova-greeter-session --client")
end)
