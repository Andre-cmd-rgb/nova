-- Dictation (the shell's nova.dictation): hold SUPER + D and speak, and the
-- words are pasted where the cursor is once it is let go. A tap leaves the
-- microphone on until the next press; the shell tells a hold from a tap by
-- the time between the two.
nova.bind("SUPER + D", "Dictation (hold to speak, tap for hands-free)", "nova-shell -q dictation press")
nova.bind("SUPER + D", nil, "nova-shell -q dictation release", { release = true })

-- ESCAPE cancels, while the dictation pill is on screen and only then.
nova.bind_while_layer("nova-dictation", function()
  return { nova.bind("ESCAPE", "Cancel dictation", "nova-shell -q dictation cancel") }
end)
