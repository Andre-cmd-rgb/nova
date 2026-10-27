-- Dictation (the shell's nova.dictation): hold SUPER + D and speak, and the
-- words are pasted where the cursor is when it is let go. A tap leaves the
-- microphone on until the next press. The shell tells a hold from a tap by
-- the time between the two calls.
o.bind("SUPER + D", "Dictation (hold to speak, tap for hands-free)", "nova-shell -q dictation press")
o.bind("SUPER + D", nil, "nova-shell -q dictation release", { release = true })

-- Escape cancels while the pill is on screen, and only then, as the region
-- picker's keys in utilities.lua do: the bind lives as long as the pill's
-- layer, and its handle is removed rather than every binding of the key.
local escape_bind = nil

hl.on("layer.opened", function(layer)
  if layer.namespace == "nova-dictation" and not escape_bind then
    escape_bind = hl.bind("ESCAPE", hl.dsp.exec_cmd("nova-shell -q dictation cancel"), { description = "Cancel dictation" })
  end
end)

hl.on("layer.closed", function(layer)
  if layer.namespace == "nova-dictation" and escape_bind then
    escape_bind:unbind()
    escape_bind = nil
  end
end)
