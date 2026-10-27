-- Volume, brightness, keyboard backlight, and touchpad controls. The volume
-- and brightness keys are the shell's global shortcuts (its nova.keys
-- service): a press takes no process for the volume and one brightnessctl for
-- the backlight. The shell repeats a held one itself, as a global shortcut
-- gets a press and a release and nothing between.
o.bind("XF86AudioRaiseVolume", "Volume up", hl.dsp.global("nova:volume-up"), { locked = true })
o.bind("XF86AudioLowerVolume", "Volume down", hl.dsp.global("nova:volume-down"), { locked = true })
o.bind("XF86AudioMute", "Mute", hl.dsp.global("nova:volume-mute"), { locked = true })
o.bind("XF86AudioMicMute", "Mute microphone", "nova-audio-input-mute", { locked = true })
o.bind("XF86MonBrightnessUp", "Brightness up", hl.dsp.global("nova:brightness-up"), { locked = true })
o.bind("XF86MonBrightnessDown", "Brightness down", hl.dsp.global("nova:brightness-down"), { locked = true })
o.bind("SHIFT + XF86MonBrightnessUp", "Brightness maximum", hl.dsp.global("nova:brightness-max"), { locked = true })
o.bind("SHIFT + XF86MonBrightnessDown", "Brightness minimum", hl.dsp.global("nova:brightness-min"), { locked = true })
o.bind("XF86KbdBrightnessUp", "Keyboard brightness up", "nova-brightness-keyboard up", { locked = true, repeating = true })
o.bind("XF86KbdBrightnessDown", "Keyboard brightness down", "nova-brightness-keyboard down", { locked = true, repeating = true })
o.bind("XF86KbdLightOnOff", "Keyboard backlight cycle", "nova-brightness-keyboard cycle", { locked = true })
o.bind_toggle("XF86TouchpadToggle", "Toggle touchpad", "touchpad", { locked = true })
o.bind("XF86TouchpadOn", "Enable touchpad", "nova-toggle-touchpad on", { locked = true })
o.bind("XF86TouchpadOff", "Disable touchpad", "nova-toggle-touchpad off", { locked = true })

-- Precise volume and brightness controls.
o.bind("ALT + XF86AudioRaiseVolume", "Volume up precise", hl.dsp.global("nova:volume-up-fine"), { locked = true })
o.bind("ALT + XF86AudioLowerVolume", "Volume down precise", hl.dsp.global("nova:volume-down-fine"), { locked = true })
o.bind("ALT + XF86MonBrightnessUp", "Brightness up precise", hl.dsp.global("nova:brightness-up-fine"), { locked = true })
o.bind("ALT + XF86MonBrightnessDown", "Brightness down precise", hl.dsp.global("nova:brightness-down-fine"), { locked = true })

-- Media controls.
o.bind("XF86AudioNext", "Next track", "nova-shell media next", { locked = true })
o.bind("ALT + XF86AudioPlay", "Next track", "nova-shell media next", { locked = true })
o.bind("XF86AudioPause", "Pause", "nova-shell media playPause", { locked = true })
o.bind("XF86AudioPlay", "Play", "nova-shell media playPause", { locked = true })
o.bind("XF86AudioPrev", "Previous track", "nova-shell media previous", { locked = true })
o.bind("ALT + SHIFT + XF86AudioPlay", "Previous track", "nova-shell media previous", { locked = true })
o.bind("XF86Eject", "Eject media", "eject", { locked = true })

o.bind("SHIFT + XF86AudioMute", "Switch audio output", "nova-audio-output-switch", { locked = true })
o.bind("SHIFT + XF86AudioPause", "Switch media source", "nova-audio-source-switch", { locked = true })
o.bind("SHIFT + XF86AudioPlay", "Switch media source", "nova-audio-source-switch", { locked = true })
