-- Keys stay dead until the lock screen holds the session, unless someone has
-- already typed this user's password.
--
-- greetd marks a session started after a password check NOVA_LOGIN=password.
-- Any other, the autologin at boot above all, starts in the nova-boot submap,
-- where no key does anything; the shell leaves it once Hyprland confirms the
-- lock is up, and from then Hyprland itself runs only binds marked `locked`
-- until the user unlocks.
if os.getenv("NOVA_LOGIN") ~= "password" then
  -- Hyprland makes a submap only once a bind is made in it, and entering one
  -- that does not exist is an error: the switch would fail over the lock
  -- screen and leave every key live. This bind does nothing, on a key few
  -- keyboards have.
  hl.define_submap("nova-boot", function()
    hl.bind("F24", function() end)
  end)

  hl.on("hyprland.start", function()
    hl.dispatch(hl.dsp.submap("nova-boot"))
  end)
end
