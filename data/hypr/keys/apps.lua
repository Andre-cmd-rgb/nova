-- The apps a key opens. Change one in ~/.config/hypr/bindings.lua: unbind the
-- key, then bind it again.
nova.bind("SUPER + RETURN", "Terminal", { nova = "terminal" })
nova.bind("SUPER + SHIFT + RETURN", "Browser", { nova = "browser" })
nova.bind("SUPER + SHIFT + F", "File manager", { nova = "nautilus" })
nova.bind("SUPER + ALT + SHIFT + F", "File manager (cwd)", { nova = "nautilus-cwd" })
nova.bind("SUPER + SHIFT + B", "Browser", { nova = "browser" })
nova.bind("SUPER + SHIFT + ALT + B", "Browser (private)", { nova = "browser --private" })
nova.bind("SUPER + SHIFT + N", "Editor", { nova = "editor" })
