-- Volume, brightness, the keyboard light, the touchpad and media keys. Every
-- one of them works on the lock screen too.

local function key(keys, description, action)
  nova.bind(keys, description, action, { locked = true })
end

-- Volume, brightness and the keyboard light are the shell's global shortcuts
-- (its nova.keys service): a press starts no process, or one lookup behind a
-- speaker tuning, and a backlight step one brightnessctl. A global shortcut
-- gets a press and a release and nothing between, so the shell repeats a held
-- key itself.
local function shell(name)
  return hl.dsp.global("nova:" .. name)
end

key("XF86AudioRaiseVolume", "Volume up", shell("volume-up"))
key("XF86AudioLowerVolume", "Volume down", shell("volume-down"))
key("XF86AudioMute", "Mute", shell("volume-mute"))
key("XF86AudioMicMute", "Mute microphone", "nova-audio-input-mute")
key("XF86MonBrightnessUp", "Brightness up", shell("brightness-up"))
key("XF86MonBrightnessDown", "Brightness down", shell("brightness-down"))
key("SHIFT + XF86MonBrightnessUp", "Brightness maximum", shell("brightness-max"))
key("SHIFT + XF86MonBrightnessDown", "Brightness minimum", shell("brightness-min"))
key("XF86KbdBrightnessUp", "Keyboard brightness up", shell("keyboard-up"))
key("XF86KbdBrightnessDown", "Keyboard brightness down", shell("keyboard-down"))
key("XF86KbdLightOnOff", "Keyboard backlight cycle", shell("keyboard-cycle"))
key("XF86TouchpadToggle", "Toggle touchpad", "nova-toggle-touchpad")
key("XF86TouchpadOn", "Enable touchpad", "nova-toggle-touchpad on")
key("XF86TouchpadOff", "Disable touchpad", "nova-toggle-touchpad off")

-- With ALT, in finer steps.
key("ALT + XF86AudioRaiseVolume", "Volume up precise", shell("volume-up-fine"))
key("ALT + XF86AudioLowerVolume", "Volume down precise", shell("volume-down-fine"))
key("ALT + XF86MonBrightnessUp", "Brightness up precise", shell("brightness-up-fine"))
key("ALT + XF86MonBrightnessDown", "Brightness down precise", shell("brightness-down-fine"))

-- The player the shell shows (its media service).
key("XF86AudioNext", "Next track", "nova-shell media next")
key("ALT + XF86AudioPlay", "Next track", "nova-shell media next")
key("XF86AudioPause", "Pause", "nova-shell media playPause")
key("XF86AudioPlay", "Play", "nova-shell media playPause")
key("XF86AudioPrev", "Previous track", "nova-shell media previous")
key("ALT + SHIFT + XF86AudioPlay", "Previous track", "nova-shell media previous")
key("XF86Eject", "Eject media", "eject")

key("SHIFT + XF86AudioMute", "Switch audio output", "nova-audio-output-switch")
key("SHIFT + XF86AudioPause", "Switch media source", "nova-audio-source-switch")
key("SHIFT + XF86AudioPlay", "Switch media source", "nova-audio-source-switch")
