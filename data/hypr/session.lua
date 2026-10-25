-- Only a session that greetd started after a password check (NOVA_LOGIN=password)
-- has an authenticated user. Every other one, the boot autologin above all, sits
-- in a submap where no key does anything until the shell's lock is secure. The
-- shell resets the submap once the compositor confirms the lock; from then on
-- Hyprland itself only runs binds marked `locked` until the user unlocks.
if os.getenv("NOVA_LOGIN") ~= "password" then
  -- Hyprland registers a submap only once it holds a bind. Left empty, it could
  -- not be entered: the start hook below failed with a Lua runtime error over
  -- the lock screen, and every key worked until the lock was up. The bind does
  -- nothing, on a key few keyboards have.
  hl.define_submap("nova-boot", function()
    hl.bind("F24", function() end)
  end)

  hl.on("hyprland.start", function()
    hl.dispatch(hl.dsp.submap("nova-boot"))
  end)
end
