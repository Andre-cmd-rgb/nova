-- Windows, workspaces, groups and monitors.
--
-- Number keys are bound by keycode (code:10 is 1, through code:19 for 0), and
-- - and = by code:20 and code:21, so they are the same keys in every layout.

local dsp = hl.dsp

nova.bind("SUPER + W", "Close window", dsp.window.close())
nova.bind("CTRL + ALT + DELETE", "Close all windows", "nova-hyprland-window-close-all")

nova.bind("SUPER + J", "Toggle window split", dsp.layout("togglesplit"))
nova.bind("SUPER + P", "Pseudo window", dsp.window.pseudo())
nova.bind("SUPER + T", "Toggle window floating/tiling", dsp.window.float({ action = "toggle" }))
nova.bind("SUPER + F", "Full screen", dsp.window.fullscreen({ mode = "fullscreen" }))
nova.bind("SUPER + CTRL + F", "Tiled full screen", "nova-hyprland-window-tiled-fullscreen-toggle")
nova.bind("SUPER + ALT + F", "Full width", dsp.window.fullscreen({ mode = "maximized" }))
nova.bind("SUPER + O", "Pop window out (float & pin)", "nova-hyprland-window-pop")
nova.bind("SUPER + ALT + Home", "Save window width", "nova-hyprland-window-width save")
nova.bind("SUPER + Home", "Restore window width", "nova-hyprland-window-width restore")
nova.bind("SUPER + L", "Toggle workspace layout", "nova-hyprland-workspace-layout-toggle")

nova.bind("SUPER + LEFT", "Focus on left window", dsp.focus({ direction = "l" }))
nova.bind("SUPER + RIGHT", "Focus on right window", dsp.focus({ direction = "r" }))
nova.bind("SUPER + UP", "Focus on above window", dsp.focus({ direction = "u" }))
nova.bind("SUPER + DOWN", "Focus on below window", dsp.focus({ direction = "d" }))

for number = 1, 10 do
  local key = "code:" .. (number + 9)
  local workspace = tostring(number)
  nova.bind("SUPER + " .. key, "Switch to workspace " .. number, dsp.focus({ workspace = workspace }))
  nova.bind("SUPER + SHIFT + " .. key, "Move window to workspace " .. number, dsp.window.move({ workspace = workspace }))
  nova.bind(
    "SUPER + SHIFT + ALT + " .. key,
    "Move window silently to workspace " .. number,
    dsp.window.move({ workspace = workspace, follow = false })
  )
end

nova.bind("SUPER + S", "Toggle scratchpad", dsp.workspace.toggle_special("scratchpad"))
nova.bind("SUPER + ALT + S", "Move window to scratchpad", dsp.window.move({ workspace = "special:scratchpad", follow = false }))

nova.bind("SUPER + TAB", "Next workspace", dsp.focus({ workspace = "e+1" }))
nova.bind("SUPER + SHIFT + TAB", "Previous workspace", dsp.focus({ workspace = "e-1" }))
nova.bind("SUPER + CTRL + TAB", "Former workspace", dsp.focus({ workspace = "previous" }))

nova.bind("SUPER + SHIFT + ALT + LEFT", "Move workspace to left monitor", dsp.workspace.move({ monitor = "l" }))
nova.bind("SUPER + SHIFT + ALT + RIGHT", "Move workspace to right monitor", dsp.workspace.move({ monitor = "r" }))
nova.bind("SUPER + SHIFT + ALT + UP", "Move workspace to up monitor", dsp.workspace.move({ monitor = "u" }))
nova.bind("SUPER + SHIFT + ALT + DOWN", "Move workspace to down monitor", dsp.workspace.move({ monitor = "d" }))

nova.bind("SUPER + SHIFT + LEFT", "Swap window to the left", dsp.window.swap({ direction = "l" }))
nova.bind("SUPER + SHIFT + RIGHT", "Swap window to the right", dsp.window.swap({ direction = "r" }))
nova.bind("SUPER + SHIFT + UP", "Swap window up", dsp.window.swap({ direction = "u" }))
nova.bind("SUPER + SHIFT + DOWN", "Swap window down", dsp.window.swap({ direction = "d" }))

-- ALT + TAB cycles the windows and raises the one it lands on, which a
-- floating window behind another needs.
nova.bind("ALT + TAB", "Focus on next window", dsp.window.cycle_next())
nova.bind("ALT + SHIFT + TAB", "Focus on previous window", dsp.window.cycle_next({ next = false }))
nova.bind("ALT + TAB", "Reveal active window on top", dsp.window.bring_to_top())
nova.bind("ALT + SHIFT + TAB", "Reveal active window on top", dsp.window.bring_to_top())

nova.bind("CTRL + ALT + TAB", "Focus on next monitor", dsp.focus({ monitor = "+1" }))
nova.bind("CTRL + ALT + SHIFT + TAB", "Focus on previous monitor", dsp.focus({ monitor = "-1" }))

-- Resizing with - and =: 100 px a press, 25 with ALT, 300 with CTRL.
for _, step in ipairs({ { "", 100, "" }, { "ALT + ", 25, " a little" }, { "CTRL + ", 300, " a lot" } }) do
  local mods, px, how = step[1], step[2], step[3]
  local function resize(x, y) return dsp.window.resize({ x = x, y = y, relative = true }) end
  nova.bind("SUPER + " .. mods .. "code:20", "Expand window left" .. how, resize(-px, 0))
  nova.bind("SUPER + " .. mods .. "code:21", "Shrink window left" .. how, resize(px, 0))
  nova.bind("SUPER + SHIFT + " .. mods .. "code:20", "Shrink window up" .. how, resize(0, -px))
  nova.bind("SUPER + SHIFT + " .. mods .. "code:21", "Expand window down" .. how, resize(0, px))
end

nova.bind("SUPER + mouse_down", "Scroll active workspace forward", dsp.focus({ workspace = "e+1" }))
nova.bind("SUPER + mouse_up", "Scroll active workspace backward", dsp.focus({ workspace = "e-1" }))

nova.bind("SUPER + mouse:272", "Move window", dsp.window.drag(), { mouse = true })
nova.bind("SUPER + mouse:273", "Resize window", dsp.window.resize(), { mouse = true })

nova.bind("SUPER + G", "Toggle window grouping", dsp.group.toggle())
nova.bind("SUPER + ALT + G", "Move active window out of group", dsp.window.move({ out_of_group = true }))

nova.bind("SUPER + ALT + LEFT", "Move window to group on left", dsp.window.move({ into_group = "l" }))
nova.bind("SUPER + ALT + RIGHT", "Move window to group on right", dsp.window.move({ into_group = "r" }))
nova.bind("SUPER + ALT + UP", "Move window to group on top", dsp.window.move({ into_group = "u" }))
nova.bind("SUPER + ALT + DOWN", "Move window to group on bottom", dsp.window.move({ into_group = "d" }))

nova.bind("SUPER + ALT + TAB", "Next window in group", dsp.group.next())
nova.bind("SUPER + ALT + SHIFT + TAB", "Previous window in group", dsp.group.prev())
nova.bind("SUPER + CTRL + LEFT", "Move grouped window focus left", dsp.group.prev())
nova.bind("SUPER + CTRL + RIGHT", "Move grouped window focus right", dsp.group.next())
nova.bind("SUPER + ALT + mouse_down", "Next window in group", dsp.group.next())
nova.bind("SUPER + ALT + mouse_up", "Previous window in group", dsp.group.prev())
for index = 1, 5 do
  nova.bind("SUPER + ALT + code:" .. (index + 9), "Switch to group window " .. index, dsp.group.active({ index = index }))
end

nova.bind("SUPER + SLASH", "Monitor scaling up", "nova-hyprland-monitor-scaling up")
nova.bind("SUPER + ALT + SLASH", "Monitor scaling down", "nova-hyprland-monitor-scaling down")
