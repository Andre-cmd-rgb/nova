# Keys and commands

Every key Nova binds, and the `nova` command's groups. Super+K searches the keys on the computer itself and runs the one you pick; `nova help` lists every command.

The number keys, minus and equals are bound by position, so they are the same keys in every keyboard layout.

## Apps and menus

| Key | Does |
|---|---|
| Super+Space | the menu (the Copilot key too) |
| Super+Alt+Space | the apps |
| Super+Ctrl+C, Super+Ctrl+O | the Capture menu, the Toggle menu |
| Super+Escape | the System menu |
| Super+Ctrl+E | emoji |
| Super+K | every key, searchable |
| Super+Return | a terminal, in the focused terminal's directory |
| Super+Shift+Return, Super+Shift+B | the browser; Super+Shift+Alt+B a private window |
| Super+Shift+F | Files; Super+Alt+Shift+F in the focused terminal's directory |
| Super+Shift+N | the editor |
| Super+Ctrl+T | Activity (btop) |
| Calculator key | the Calculator |

## Windows

| Key | Does |
|---|---|
| Super+W | close the window |
| Ctrl+Alt+Delete | close every window |
| Super+arrows, Super+Shift+arrows | focus, swap the window that way |
| Alt+Tab, Alt+Shift+Tab | the next window, the one before |
| Super+T | floating or tiled |
| Super+F, Super+Ctrl+F, Super+Alt+F | full screen; full screen within the tile; full width |
| Super+O | pop out: floating, and pinned on every workspace |
| Super+J | split the other way |
| Super+P | the window at its own size, centred in its tile |
| Super+L | this workspace's layout: dwindle or scrolling |
| Super+minus, Super+equals | resize the window across; with Shift up and down; with Alt a little, with Ctrl a lot |
| Super+Alt+Home, Super+Home | remember the window's width, give it back |
| Super+drag, Super+right-drag | move, resize |
| Super+Backspace | the window see-through or solid |
| Super+Shift+Backspace | gaps between windows or none |
| Super+Ctrl+Backspace | a lone window square, or full size |

### Groups

| Key | Does |
|---|---|
| Super+G | make the window a group, or undo it |
| Super+Alt+arrows, Super+Alt+G | move the window into the group that way, out of its group |
| Super+Alt+Tab, Super+Alt+Shift+Tab | the next, previous window in the group (also Super+Ctrl+Left and Right, Super+Alt and the wheel) |
| Super+Alt+1 to 5 | the group's first to fifth window |

## Workspaces and displays

| Key | Does |
|---|---|
| Super+1 to Super+0 | workspace 1 to 10 |
| Super+Shift+1 to 0 | move the window there; with Alt too, and stay here |
| Super+Tab, Super+Shift+Tab | the next, previous workspace with windows (also Super and the wheel) |
| Super+Ctrl+Tab | the workspace you were on |
| Super+S, Super+Alt+S | the scratchpad; move the window there |
| Super+Shift+Alt+arrows | move the workspace to the display that way |
| Ctrl+Alt+Tab, Ctrl+Alt+Shift+Tab | the next, previous display |
| Super+slash, Super+Alt+slash | scale the display up, down |
| Super+Ctrl+Delete | the laptop's display on or off; with Alt, mirror it |
| Super+Ctrl+Z, Super+Ctrl+Alt+Z | zoom in, back to normal |

Three fingers sideways on a touchpad go through the workspaces with windows, as Super+Tab does.

## Capture and the clipboard

| Key | Does |
|---|---|
| Print | a screenshot: click a window or drag a region |
| Alt+Print | start or stop a screen recording |
| Super+Print | pick a color off the screen |
| Super+Ctrl+Print | copy the text in a region (OCR, after `sudo pacman -S tesseract-data-eng`) |
| Super+C, Super+V, Super+X | copy, paste, cut in any window, a terminal too |
| Super+Ctrl+V | the clipboard's history |

## The desktop

| Key | Does |
|---|---|
| Super+Ctrl+L | lock |
| Super+D | dictation: hold and speak, or tap for hands-free; Esc cancels |
| Super+Ctrl+I | Caffeine |
| Super+Ctrl+N | night light |
| Super+Shift+Space | hide or show the bar |
| Super+Ctrl+Space, Super+Shift+Ctrl+Space | the background picker, the theme picker |
| Super+comma, Super+Shift+comma | dismiss the last notification, all of them |
| Super+Ctrl+comma | Do Not Disturb |
| Super+Alt+comma, Super+Shift+Alt+comma | open the last notification, the history |
| Super+Ctrl+A, B, W, P, D | the sound, Bluetooth, network, power, display panel |
| Super+Ctrl+Alt+D, Super+Ctrl+Alt+W | the clock's calendar, the weather |
| Super+Ctrl+Alt+T, Super+Ctrl+Alt+B | the time, the battery left, in a notification |
| Super+Ctrl+1 to 9 | the panels on the bar's right, by place |

Volume, brightness, keyboard light, touchpad and media keys work on the lock screen too. With Alt, volume and brightness move in finer steps; Shift+Mute switches to the next output.

## Changing a key

Your keys are in `~/.config/hypr/bindings.lua`. To change one of Nova's, unbind it and bind it again:

```lua
hl.unbind("SUPER + SPACE")
nova.bind("SUPER + SPACE", "Nova menu", "nova-menu toggle root")
```

Nova's own are in `/usr/share/nova/default/hypr/keys/`.

## The nova command

`nova <group> …` reaches every part of Nova; `nova help <group>` lists a group's commands.

| Group | For |
|---|---|
| `nova settings <page>`, `nova menu summon <entry>` | open Settings at a page, the menu at an entry |
| `nova theme`, `nova font`, `nova bar` | themes and backgrounds, the font, the bar ([themes](themes.md)) |
| `nova apps` | the App Center in a terminal ([apps](apps.md)) |
| `nova update`, `nova recovery` | updates, and the boot menu's snapshots ([updates](updates.md)) |
| `nova doctor` | look the system over; `--bundle` writes a file for a bug report |
| `nova power` | power modes, the discrete GPU, sleep, the undervolt ([power](power.md)) |
| `nova notification iphone` | [iPhone notifications](iphone.md) |
| `nova dictation`, `nova calendar`, `nova calculator` | the apps of those names |
| `nova caffeine`, `nova nightlight`, `nova notification schedule` | keeping awake, the night light, Do Not Disturb's hours |
| `nova monitor`, `nova input`, `nova display text size` | displays, keyboard and mouse, text size |
| `nova audio`, `nova bluetooth`, `nova network band`, `nova dns` | sound, Bluetooth, Wi-Fi band, DNS |
| `nova battery`, `nova screentime` | battery life and its limit, Screen Time |
| `nova restart shell\|audio\|wifi\|bluetooth` | start a part of the desktop again |
| `nova patch` | fixes for one computer ([patches](patches.md)) |
| `nova usb` | make an installer stick ([install](install.md)) |
