-- Keyboard, mouse and touchpad. What you set here wins over Nova's own
-- (/usr/share/nova/default/hypr/input.lua); each line below is one change to
-- uncomment. https://wiki.hypr.land/Configuring/Basics/Variables/#input
--
-- Settings → Keyboard & Mouse sets the layouts, the key repeat, the pointer's
-- speed, the scrolling and tapping, and what it sets wins over this file.
--
-- The keyboard layout comes from /etc/vconsole.conf (XKBLAYOUT), which the
-- installer set, so the lock screen and the console agree with the desktop.

-- A second layout, Left Alt + Right Alt to switch, Nova's options kept:
-- hl.config({ input = { kb_layout = "us,de", kb_options = "compose:caps,shift:both_capslock_cancel,grp:alts_toggle" } })

-- Keys that repeat later and slower when held, as Hyprland has it:
-- hl.config({ input = { repeat_delay = 600, repeat_rate = 25 } })

-- A slower mouse, at an even speed however fast it is moved:
-- hl.config({ input = { sensitivity = -0.3, accel_profile = "flat" } })

-- The touchpad scrolling as a mouse wheel does, not with the content:
-- hl.config({ input = { touchpad = { natural_scroll = false } } })

-- No swipe between workspaces with three fingers:
-- hl.gesture({ fingers = 3, direction = "horizontal", action = "unset" })
