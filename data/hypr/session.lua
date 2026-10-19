-- An autologin session starts with nobody authenticated. Until the shell's lock
-- is secure, sit in a submap with no binds, so no key does anything. The shell
-- resets the submap once the compositor confirms the lock; from then on
-- Hyprland itself only runs binds marked `locked` until the user unlocks.
if os.getenv("NOVA_AUTOLOGIN") == "1" then
  hl.define_submap("nova-boot", function() end)

  hl.on("hyprland.start", function()
    hl.dispatch(hl.dsp.submap("nova-boot"))
  end)
end
