-- Essential application bindings.
o.bind("SUPER + RETURN", "Terminal", { nova = "terminal" })
o.bind("SUPER + SHIFT + RETURN", "Browser", { nova = "browser" })
o.bind("SUPER + SHIFT + F", "File manager", { nova = "nautilus" })
o.bind("SUPER + ALT + SHIFT + F", "File manager (cwd)", { nova = "nautilus-cwd" })
o.bind("SUPER + SHIFT + B", "Browser", { nova = "browser" })
o.bind("SUPER + SHIFT + ALT + B", "Browser (private)", { nova = "browser --private" })
o.bind("SUPER + SHIFT + N", "Editor", { nova = "editor" })

if o.preinstalled_bindings_enabled() then
  -- Bindings for preinstalled Nova applications, TUIs, and web apps.
  o.bind("SUPER + ALT + RETURN", "Tmux", { nova = "terminal-tmux" })
  o.bind("SUPER + CTRL + RETURN", "Herdr", { nova = "terminal-herdr" })
  o.bind("SUPER + SHIFT + M", "Music", { nova = "spotify" })
  o.bind("SUPER + SHIFT + ALT + M", "Music TUI", { tui = "cliamp", focus = true })
  o.bind("SUPER + SHIFT + D", "Docker", { tui = "nova-launch-docker-tui" })
  o.bind("SUPER + SHIFT + G", "Signal", { nova = "signal" })
  o.bind("SUPER + SHIFT + O", "Obsidian", { launch = "obsidian", focus = "^obsidian$" })
  o.bind("SUPER + SHIFT + W", "Omawrite", { launch = "omawrite" })
  o.bind("SUPER + SHIFT + SLASH", "Passwords", { nova = "1password" })

  o.bind("SUPER + SHIFT + A", "ChatGPT", { webapp = "https://chatgpt.com" })
  o.bind("SUPER + SHIFT + ALT + A", "Grok", { webapp = "https://grok.com" })
  o.bind("SUPER + SHIFT + C", "Calendar", { webapp = "https://app.hey.com/calendar/weeks/" })
  o.bind("SUPER + SHIFT + E", "Email", { webapp = "https://app.hey.com" })
  o.bind("SUPER + SHIFT + ALT + E", "New email", { webapp = "https://app.hey.com/messages/new?display=standalone&new_window=true" })
  o.bind("SUPER + SHIFT + Y", "YouTube", { webapp = "https://youtube.com/" })
  o.bind("SUPER + SHIFT + ALT + G", "WhatsApp", { webapp = "https://web.whatsapp.com/", focus = true })
  o.bind( "SUPER + SHIFT + CTRL + G", "Google Messages", { webapp = "https://messages.google.com/web/conversations", focus = true })
  o.bind("SUPER + SHIFT + P", "Google Photos", { webapp = "https://photos.google.com/", focus = true })
  o.bind("SUPER + SHIFT + S", "Google Maps", { webapp = "https://maps.google.com/", focus = true })
  o.bind("SUPER + SHIFT + X", "X", { webapp = "https://x.com/" })
  o.bind("SUPER + SHIFT + ALT + X", "X Post", { webapp = "https://x.com/compose/post" })
end
