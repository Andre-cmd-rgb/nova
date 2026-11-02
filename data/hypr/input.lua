-- Keyboard, mouse and touchpad.
-- https://wiki.hypr.land/Configuring/Basics/Variables/#input

local keyboard = require("default.hypr.keyboard").layout()

-- Caps Lock is the compose key. Caps Lock itself is both Shifts together, in
-- the _cancel kind, which the next Shift alone turns off again: both pressed
-- by accident while typing set right themselves.
local kb_options = "compose:caps,shift:both_capslock_cancel"
if keyboard.options ~= "" then kb_options = kb_options .. "," .. keyboard.options end

hl.config({
  input = {
    kb_layout = keyboard.layout,
    kb_variant = keyboard.variant,
    kb_model = "",
    kb_options = kb_options,
    kb_rules = "",
    follow_mouse = 1,
    sensitivity = 0,
    -- A held key repeats sooner, and faster, than Hyprland's 600 ms and 25 a second.
    repeat_rate = 40,
    repeat_delay = 250,
    numlock_by_default = true,
    touchpad = {
      -- Content follows the fingers.
      natural_scroll = true,
      -- One finger clicks left, two right and three middle, anywhere on the pad.
      clickfinger_behavior = true,
      scroll_factor = 0.4,
    },
  },

  -- A key press or a mouse move turns the displays back on once they are off.
  misc = {
    key_press_enables_dpms = true,
    mouse_move_enables_dpms = true,
  },
})

-- Terminals each take a touchpad scroll their own way: faster in these three,
-- slower in Ghostty.
nova.window("(Alacritty|kitty|foot)", { scroll_touchpad = 1.5 })
nova.window("com.mitchellh.ghostty", { scroll_touchpad = 0.2 })
