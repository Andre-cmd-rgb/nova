-- Window and layer rules. Hyprland applies every rule that matches a window,
-- in order, so where two set the same thing the later one wins: keep the
-- order. https://wiki.hypr.land/Configuring/Basics/Window-Rules/

-- No program maximizes itself; the layout decides a window's size.
nova.window(".*", { suppress_event = "maximize" })

-- Every window starts a little see-through (the rule at the end). A rule
-- below that takes the tag off a window keeps it opaque, or gives it its own.
nova.window(".*", { tag = "+default-opacity" })

-- What an X11 program drags (an icon, a tab) is a nameless floating window,
-- which must not take the focus mid-drag.
nova.window(
  { class = "^$", title = "^$", xwayland = true, float = true, fullscreen = false, pin = false },
  { no_focus = true }
)

-- Browsers are opaque while focused, and Chromium's tile even when they ask
-- to float.
nova.window(
  "((google-)?[cC]hrom(e|ium)|[bB]rave-browser|[mM]icrosoft-edge|Vivaldi-stable|helium)",
  { tag = "+chromium-based-browser" }
)
nova.window("([fF]irefox|zen|librewolf)", { tag = "+firefox-based-browser" })
nova.window({ tag = "chromium-based-browser" }, { tag = "-default-opacity", tile = true, opacity = "1.0 0.985" })
nova.window({ tag = "firefox-based-browser" }, { tag = "-default-opacity", opacity = "1.0 0.985" })
-- YouTube and Zoom installed as web apps are video, and fully opaque.
local video_web_apps = "(^.+-youtube\\.com__.*$|^.+-app\\.zoom\\.us__wc_home.*$)"
nova.window(video_web_apps, { tag = "-chromium-based-browser" })
nova.window(video_web_apps, { tag = "-default-opacity" })
-- The "… is sharing your screen" bar a browser opens goes out of sight.
nova.window({ title = ".*is sharing.*" }, { workspace = "special silent" })

nova.window("(Share|localsend)", { float = true, center = true })
nova.window("localsend", { size = { 1100, 700 } })

-- The shell's bar, menus and pickers appear at once, without the fade layers
-- get. Panels fade themselves, and skip it when one hands over to another.
hl.layer_rule({ match = { namespace = "nova-bar" }, no_anim = true, animation = "none" })
hl.layer_rule({
  match = { namespace = "^(nova-menu|nova-image-selector|nova-emojis|nova-clipboard|nova-keyboard-panel)$" },
  no_anim = true,
  animation = "none",
})
-- Settings and the Calendar, the shell's windows, float in the middle of the
-- screen at the size they ask for, opaque: they draw in the theme's own
-- background, and text behind would show through.
nova.window(
  { class = "^org\\.quickshell$", title = "^(Settings|Calendar)$" },
  { float = true, center = true, tag = "-default-opacity" }
)

-- Picture-in-picture: a small opaque window at the top right, on every
-- workspace. Google Meet's is titled after the meeting, and goes bottom right.
nova.window({ title = "(Picture.?in.?[Pp]icture)" }, { tag = "+pip" })
local function pip(match, move)
  nova.window(match, {
    tag = "-default-opacity",
    float = true,
    pin = true,
    size = { 600, 338 },
    keep_aspect_ratio = true,
    border_size = 0,
    opacity = "1 1",
    move = move,
  })
end
pip({ tag = "pip" }, { "(monitor_w-window_w-40)", "(monitor_h*0.04)" })
pip({ tag = "chromium-based-browser", title = "^Meet - .+" }, { "(monitor_w-window_w-40)", "(monitor_h-window_h-40)" })

nova.window("qemu", { tag = "-default-opacity", opacity = "1 1" })

-- The screenshot region picker (slurp) shows at once.
hl.layer_rule({ match = { namespace = "selection" }, no_anim = true, animation = "none" })

nova.window("steam", { float = true, idle_inhibit = "fullscreen" })
nova.window({ class = "steam", title = "Steam" }, { center = true, size = { 1100, 700 } })
nova.window("steam.*", { tag = "-default-opacity", opacity = "1 1" })
nova.window({ class = "steam", title = "Friends List" }, { size = { 460, 800 } })

-- Windows tagged floating-window float in the middle of the screen at 875x600,
-- or at most of a small screen (the Raspberry Pi's 1024x600 panel).
nova.window({ tag = "floating-window" }, {
  float = true,
  center = true,
  size = { "(min(875, monitor_w*0.94))", "(min(600, monitor_h*0.86))" },
})
nova.window(
  "(org.nova.btop|org.nova.terminal|org.nova.bash|org.codeberg.dnkl.foot|org.gnome.NautilusPreviewer|org.gnome.Evince|TUI.float|imv|mpv|org.gnome.Loupe)",
  { tag = "+floating-window" }
)
-- Every window of the GTK portal is a dialog: a file picker, a screen to
-- share, a permission to give.
nova.window("xdg-desktop-portal-gtk", { tag = "+floating-window" })
nova.window({
  class = "(sublime_text|DesktopEditors|org.gnome.Nautilus)",
  title = "^(Open.*Files?|Open [F|f]older.*|Save.*Files?|Save.*As|Save|All Files|.*wants to [open|save].*|[C|c]hoose.*)",
}, { tag = "+floating-window" })

-- Video, images and recording are never see-through.
nova.window(
  "^(zoom|vlc|mpv|org.kde.kdenlive|com.obsproject.Studio|com.github.PintaProject.Pinta|imv|org.gnome.Loupe|org.gnome.NautilusPreviewer)$",
  { tag = "-default-opacity", opacity = "1 1" }
)

-- A window popped out (SUPER + O) has round corners, to tell it apart.
nova.window({ tag = "pop" }, { rounding = 8 })

-- The screensaver (nova screensaver): a window on each display, over everything.
nova.window("org.nova.screensaver", { fullscreen = true, float = true, animation = "slide" })

-- Tag a window noidle, in rules of your own, and the screen stays on while
-- it is open.
nova.window({ tag = "noidle" }, { idle_inhibit = "always" })

-- Terminals, Nova's own windows among them, carry the terminal tag, which
-- SUPER + C and SUPER + V go by (keys/clipboard.lua) and themes can style.
-- A class is matched in full, so foot's other app ID is spelled out.
nova.window(
  "(Alacritty|kitty|com.mitchellh.ghostty|foot|org\\.codeberg\\.dnkl\\.foot|wezterm|org\\.nova\\..*|TUI\\..*)",
  { tag = "+terminal" }
)

-- Whatever still has the tag is a little see-through: 0.985 focused, 0.96 not.
nova.window({ tag = "default-opacity" }, { opacity = "0.985 0.96" })

-- A hardware profile whose GPU is short of memory bandwidth (a Raspberry Pi's)
-- makes every window opaque, the opacities above too, as the last rule wins:
-- Hyprland draws nothing under an opaque window, and under a see-through one
-- the wallpaper and every window below it, in every frame.
if nova.opaque_windows then
  nova.window(".*", { opacity = "1 1" })
end
