-- How windows look: gaps, borders, groups and their tab bar, and animations.
-- The theme sets the border colors after this (theme/templates/hyprland.lua.tpl).
-- Only what differs from Hyprland's own defaults is set: its gaps between
-- windows (5) and dwindle layout are Nova's too.
-- https://wiki.hypr.land/Configuring/Basics/Variables/

local border = { colors = { "rgba(33ccffee)", "rgba(00ff99ee)" }, angle = 45 }
local inactive_border = "rgba(595959aa)"

hl.config({
  general = {
    gaps_out = 10,
    border_size = 2,
    col = { active_border = border, inactive_border = inactive_border },
  },

  -- Round corners, which the shell's bar, menus and panels take for theirs
  -- (src/shell/Commons/Style.qml). No shadows, which cost GPU work for every
  -- window in every frame. Blur behind the terminal alone (rules.lua), which
  -- asks for it and whose background is a little see-through
  -- (theme/templates/foot.ini.tpl): a tiled one has only the desktop's
  -- background behind it, whose blur Hyprland makes once and keeps until the
  -- background changes (new_optimizations, on by default).
  decoration = {
    rounding = 8,
    shadow = { enabled = false },
    blur = { enabled = true, size = 8, passes = 3 },
  },

  -- The tab bar of a group: a tab a gradient, its title bold for the window
  -- in view. Its colours are the theme's (theme/templates/hyprland.lua.tpl).
  group = {
    col = { border_active = border, border_inactive = inactive_border },
    groupbar = {
      height = 22,
      font_size = 12,
      font_family = "monospace",
      font_weight_active = "ultraheavy",
      indicator_height = 1,
      indicator_gap = 5,
      gaps_in = 5,
      gaps_out = 0,
      gradients = true,
      gradient_rounding = 0,
      gradient_round_only_edges = false,
    },
  },
})

-- https://wiki.hypr.land/Configuring/Advanced-and-Cool/Animations/
-- Hyprland has "default" and "linear" of its own.
local function bezier(name, x1, y1, x2, y2)
  hl.curve(name, { type = "bezier", points = { { x1, y1 }, { x2, y2 } } })
end
bezier("easeOutQuint", 0.23, 1, 0.32, 1)
bezier("almostLinear", 0.5, 0.5, 0.75, 1.0)
bezier("quick", 0.15, 0, 0.1, 1)

-- Windows move, resize and open on a spring, as in the config Hyprland 0.57
-- ships as its example. A timed curve such as easeOutQuint sets off at full
-- speed: it covered nearly a fifth of a move in its first frame (222 of the
-- 1195 logical pixels the first terminal's edge goes as a second one opens),
-- so a window jumped as it began, and jumped again each time its place
-- changed before it got there, as when terminals are opened one after
-- another and each splits the last. A spring starts from rest. Sent
-- somewhere new while it moves, a window keeps its speed only as a share of
-- the way per second (hyprutils scales the speed for single numbers, not for
-- a position or a size), so a window split the other way while it is still
-- opening still turns at once, less sharply.
-- This one is damped to 0.95 of critical (damping 38; critical is 2 x the
-- square root of its stiffness, 40): it comes to rest without passing its
-- place by a pixel, and without the slow last creep of a fully damped
-- spring. The example's ("easy") overshot by 2%, an edge passing its tile by
-- 22 pixels and coming back. Gentler than easeOutQuint and a little
-- slower: a first frame of 54 pixels (222), at most 150 a frame (222), 90%
-- of the way in 0.18 s (0.15), 99% in 0.3 s (0.25).
-- A spring takes no speed; hl.animation asks for one all the same.
hl.curve("settle", { type = "spring", mass = 1, stiffness = 400, damping = 38 })

local function animate(leaf, speed, curve, style)
  hl.animation({ leaf = leaf, enabled = true, speed = speed, bezier = curve, style = style })
end
local function spring(leaf, curve, style)
  hl.animation({ leaf = leaf, enabled = true, speed = 1, spring = curve, style = style })
end
local function still(leaf)
  hl.animation({ leaf = leaf, enabled = false })
end

animate("global", 10, "default")
animate("border", 5.39, "easeOutQuint")
spring("windows", "settle")
spring("windowsIn", "settle", "popin 87%")
animate("windowsOut", 1.49, "linear", "popin 87%")
animate("fadeIn", 1.73, "almostLinear")
animate("fadeOut", 1.46, "almostLinear")
animate("fade", 3.03, "quick")
still("fadeSwitch")
animate("layers", 3.81, "easeOutQuint")
animate("layersIn", 4, "easeOutQuint", "fade")
animate("layersOut", 1.5, "linear", "fade")
animate("fadeLayersIn", 1.79, "almostLinear")
animate("fadeLayersOut", 1.39, "almostLinear")
-- Switching workspaces is instant.
still("workspaces")
animate("specialWorkspace", 3, "easeOutQuint", "slidevert")
