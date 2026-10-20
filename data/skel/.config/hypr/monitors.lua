-- Displays. https://wiki.hypr.land/Configuring/Basics/Monitors/
-- List them, with every mode each supports: hyprctl monitors all

-- Every display at its preferred mode, scaled to suit its pixel density.
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = "auto" })

-- One display in particular:
-- hl.monitor({ output = "DP-2", mode = "2560x1440@144", position = "0x0", scale = 1 })

-- Rotated (transform: 1 = 90°, 3 = 270°):
-- hl.monitor({ output = "DP-2", mode = "preferred", position = "auto", scale = 1, transform = 1 })
