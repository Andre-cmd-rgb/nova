-- Window borders in the theme's colours: the accent round the focused window
-- and the focused group, muted round the rest. A palette may give its own
-- hyprland_active_border or hyprland_inactive_border, a colour or a
-- gradient ("rgb(...) rgb(...) 45deg").
local focused = {{ hypr_gradient hyprland_active_border accent }}
local unfocused = {{ hypr_gradient hyprland_inactive_border muted }}

hl.config({
  general = { col = { active_border = focused, inactive_border = unfocused } },
  group = { col = { border_active = focused, border_inactive = unfocused } },
})
