-- Menus, panels, notifications, toggles, screen capture, and the lid.

nova.bind("SUPER + SPACE", "Nova menu", "nova-menu toggle")
nova.bind("SUPER + ALT + SPACE", "Apps menu", "nova-menu toggle apps")
nova.bind("SUPER + CTRL + E", "Emojis", "nova-shell shell toggle nova.emojis")
nova.bind("SUPER + CTRL + C", "Capture menu", "nova-menu toggle capture")
nova.bind("SUPER + CTRL + O", "Toggle menu", "nova-menu toggle toggle")
-- The Copilot key sends SUPER + SHIFT + F23 (code:201).
nova.bind("SUPER + SHIFT + code:201", "Nova menu", "nova-menu toggle root")
nova.bind("SUPER + ESCAPE", "System menu", "nova-menu toggle system")
-- The system menu, unless Settings says the button sleeps or shuts down (nova power button).
nova.bind("XF86PowerOff", "Power button", "nova-power-button press", { locked = true })
nova.bind("SUPER + K", "Keybindings", "nova-menu-keybindings")

nova.bind_toggle("SUPER + SHIFT + SPACE", "Toggle top bar", "bar")
nova.bind("SUPER + CTRL + SPACE", "Background switcher", "nova-menu toggle background")
nova.bind("SUPER + SHIFT + CTRL + SPACE", "Theme menu", "nova-menu toggle theme")
nova.bind("SUPER + BACKSPACE", "Toggle window transparency", "nova-hyprland-window-transparency-toggle")
nova.bind("SUPER + SHIFT + BACKSPACE", "Toggle window gaps", "nova-hyprland-window-gaps-toggle")
nova.bind("SUPER + CTRL + BACKSPACE", "Toggle single-window square aspect", "nova-hyprland-window-single-square-aspect-toggle")

-- xkbcommon names the key "comma"; "COMMA" matches nothing.
nova.bind("SUPER + comma", "Dismiss last notification", "nova-shell notifications dismissOne")
nova.bind("SUPER + SHIFT + comma", "Dismiss all notifications", "nova-shell notifications dismissAll")
nova.bind_toggle("SUPER + CTRL + comma", "Toggle silencing notifications", "notification-silencing")
nova.bind("SUPER + ALT + comma", "Invoke last notification", "nova-shell notifications invokeLast")
nova.bind("SUPER + SHIFT + ALT + comma", "Open notification history", "nova-shell notifications showHistory")

nova.bind("SUPER + CTRL + I", "Toggle Caffeine", "nova-caffeine toggle")
nova.bind_toggle("SUPER + CTRL + N", "Toggle nightlight", "nightlight")
nova.bind("SUPER + CTRL + Delete", "Toggle laptop display", "nova-hyprland-monitor-internal toggle")
nova.bind("SUPER + CTRL + ALT + Delete", "Toggle laptop display mirroring", "nova-hyprland-monitor-internal-mirror toggle")
-- The lid goes through nova caffeine, which hands it straight on
-- (nova-system-lid-close, nova-hyprland-monitor-clamshell) unless Caffeine is on.
nova.bind("switch:on:Lid Switch", nil, "nova-caffeine close", { locked = true })
nova.bind("switch:off:Lid Switch", nil, "nova-caffeine open", { locked = true })

nova.bind("PRINT", "Screenshot", "nova-capture-screenshot")
nova.bind("ALT + PRINT", "Screenrecording", "nova-capture-screenrecording --stop-recording || nova-menu toggle capture.screenrecord")
nova.bind("SUPER + PRINT", "Color picker", "pkill hyprpicker || hyprpicker -a")
nova.bind("SUPER + CTRL + PRINT", "Extract text (OCR) from screenshot", "nova-capture-text")

-- While the region picker (slurp, one layer per display) is up, the keyboard
-- picks too: RETURN takes the highlighted window, CTRL + RETURN the whole
-- screen, and TAB and the arrows move between windows (nova-capture-region).
nova.bind_while_layer("selection", function()
  local function pick(keys, description, mode)
    return nova.bind(keys, description, "nova-capture-region " .. mode)
  end
  local handles = {
    pick("RETURN", "Capture highlighted window", "--take-window"),
    pick("CTRL + RETURN", "Capture entire screen", "--take-fullscreen"),
    pick("TAB", "Select next window to capture", "--select-window next"),
    pick("CTRL + TAB", "Select previous window to capture", "--select-window prev"),
  }
  for _, direction in ipairs({ "left", "right", "up", "down" }) do
    handles[#handles + 1] = pick(direction:upper(), "Select window to capture", "--select-window " .. direction)
  end
  return handles
end)

nova.bind("SUPER + CTRL + ALT + T", "Show time", "nova-notification-time")
nova.bind("SUPER + CTRL + ALT + B", "Show battery remaining", "nova-notification-battery")
nova.bind("SUPER + CTRL + ALT + W", "Toggle weather", "nova-shell shell toggle nova.weather")

nova.bind("SUPER + CTRL + A", "Audio", "nova-shell shell toggle nova.audio")
nova.bind("SUPER + CTRL + B", "Bluetooth", "nova-shell shell toggle nova.bluetooth")
nova.bind("SUPER + CTRL + D", "Display", "nova-shell shell toggle nova.monitor")
nova.bind("SUPER + CTRL + ALT + D", "Calendar", "nova-shell shell toggle nova.clock")
nova.bind("SUPER + CTRL + W", "Network", "nova-shell shell toggle nova.network")
nova.bind("SUPER + CTRL + P", "Power", "nova-shell shell toggle nova.power")
nova.bind("SUPER + CTRL + T", "Activity", { tui = "btop" })

-- SUPER + CTRL + a number opens the bar's panels by place: 1 is the leftmost
-- in the bar's right section. A widget with no panel (the tray) is not
-- counted, so the number is the icon's place as it looks.
for panel = 1, 9 do
  nova.bind("SUPER + CTRL + code:" .. (panel + 9), "Bar panel " .. panel, "nova-shell -q shell togglePanelAt right " .. panel)
end

nova.bind("SUPER + CTRL + Z", "Zoom in", function()
  local zoom = hl.get_config("cursor.zoom_factor") or 1
  hl.config({ cursor = { zoom_factor = zoom + 1 } })
end)
nova.bind("SUPER + CTRL + ALT + Z", "Reset zoom", function()
  hl.config({ cursor = { zoom_factor = 1 } })
end)

nova.bind("SUPER + CTRL + L", "Lock system", "nova-system-lock")
