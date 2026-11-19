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

-- A group's tab bar sits over the wallpaper, where white text on a light
-- shade read only on a dark one. Its tabs are the theme's background, nearly
-- solid as the shell's cards are, under the theme's text: quieter for the
-- windows not in view.
hl.config({
  group = {
    groupbar = {
      text_color = "rgb({{ foreground_strip }})",
      text_color_inactive = "rgb({{ mix_strip foreground background 40% }})",
      col = { active = "rgba({{ background_strip }}f2)", inactive = "rgba({{ background_strip }}cc)" },
    },
  },
})
