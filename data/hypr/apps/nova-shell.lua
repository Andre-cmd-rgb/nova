-- Window and layer rules for the Nova Quickshell surfaces. The
-- shell-wide bar / menu / popouts are layer-shell.

-- Keep the bar instant: no layer-shell fade/slide animation.
hl.layer_rule({ match = { namespace = "nova-bar" }, no_anim = true, animation = "none" })

-- Launcher, image selector, emojis, clipboard overlays, and keyboard-driven
-- panels should pop without compositor layer fades. Panels keep their own
-- QML opacity transition for normal open/close, and skip it for panel handoff.
hl.layer_rule({ match = { namespace = "^(nova-menu|nova-image-selector|nova-emojis|nova-clipboard|nova-keyboard-panel)$" }, no_anim = true, animation = "none" })

-- The shell's own windows (Settings, Screen Time, Battery Life) float in the
-- middle of the screen at the size each one asks for, rather than tiling.
o.window({ class = "^org\\.quickshell$", title = "^(Settings|Screen Time|Battery Life)$" }, { float = true, center = true })
