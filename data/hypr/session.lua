-- Only a session that greetd started after a password check (NOVA_LOGIN=password)
-- has an authenticated user. Every other one, the boot autologin above all, sits
-- in a submap with no binds until the shell's lock is secure, so no key does
-- anything. The shell resets the submap once the compositor confirms the lock;
-- from then on Hyprland itself only runs binds marked `locked` until the user
-- unlocks.
if os.getenv("NOVA_LOGIN") ~= "password" then
  hl.define_submap("nova-boot", function() end)

  hl.on("hyprland.start", function()
    hl.dispatch(hl.dsp.submap("nova-boot"))
  end)
end
