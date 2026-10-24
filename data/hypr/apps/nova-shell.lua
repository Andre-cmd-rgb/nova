-- Window and layer rules for the Nova Quickshell surfaces. The
-- shell-wide bar / menu / popouts are layer-shell.

-- Keep the bar instant: no layer-shell fade/slide animation.
hl.layer_rule({ match = { namespace = "nova-bar" }, no_anim = true, animation = "none" })

-- Launcher, image selector, emojis, clipboard overlays, and keyboard-driven
-- panels should pop without compositor layer fades. Panels keep their own
-- QML opacity transition for normal open/close, and skip it for panel handoff.
hl.layer_rule({ match = { namespace = "^(nova-menu|nova-image-selector|nova-emojis|nova-clipboard|nova-keyboard-panel)$" }, no_anim = true, animation = "none" })

-- Settings, the shell's one window, floats in the middle of the screen at the
-- size it asks for, rather than tiling, and is opaque: it is drawn in the
-- theme's own background, and text behind it would read through. Its pages
-- move exactly as far as the touchpad says, with no acceleration of their own,
-- so the 0.4 that tames other apps (input.lua) left them crawling.
o.window({ class = "^org\\.quickshell$", title = "^Settings$" }, { float = true, center = true, tag = "-default-opacity", scroll_touchpad = 1.0 })
