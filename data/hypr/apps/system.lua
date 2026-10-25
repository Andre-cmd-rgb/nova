-- Floating windows.
o.window({ tag = "floating-window" }, { float = true })
o.window({ tag = "floating-window" }, { center = true })
-- 875x600 wherever that fits, and no more than most of a small screen (a
-- Raspberry Pi's 1024x600 panel) where it does not.
o.window({ tag = "floating-window" }, { size = { "(min(875, monitor_w*0.94))", "(min(600, monitor_h*0.86))" } })

o.window(
  "(org.nova.btop|org.nova.terminal|org.nova.bash|org.codeberg.dnkl.foot|org.gnome.NautilusPreviewer|org.gnome.Evince|TUI.float|imv|mpv)",
  {
    tag = "+floating-window",
  }
)

-- The portal only ever shows dialogs — file pickers, screen shares, permission
-- prompts — so every one of its windows belongs in the floating treatment,
-- whatever the app that asked for it titled it.
o.window("xdg-desktop-portal-gtk", { tag = "+floating-window" })
o.window({
  class = "(sublime_text|DesktopEditors|org.gnome.Nautilus)",
  title = "^(Open.*Files?|Open [F|f]older.*|Save.*Files?|Save.*As|Save|All Files|.*wants to [open|save].*|[C|c]hoose.*)",
}, { tag = "+floating-window" })

-- No transparency on media windows.
o.window(
  "^(zoom|vlc|mpv|org.kde.kdenlive|com.obsproject.Studio|com.github.PintaProject.Pinta|imv|org.gnome.NautilusPreviewer)$",
  {
    tag = "-default-opacity",
  }
)
o.window(
  "^(zoom|vlc|mpv|org.kde.kdenlive|com.obsproject.Studio|com.github.PintaProject.Pinta|imv|org.gnome.NautilusPreviewer)$",
  {
    opacity = "1 1",
  }
)

-- Popped window rounding.
o.window({ tag = "pop" }, { rounding = 8 })

-- The screensaver (nova screensaver): a window on each display, over everything.
o.window("org.nova.screensaver", { fullscreen = true, float = true, animation = "slide" })

-- Prevent idle while open.
o.window({ tag = "noidle" }, { idle_inhibit = "always" })
