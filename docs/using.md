# Using Nova

This page covers the keys, the menu, the bar, Settings page by page, and the parts of the desktop you meet every day: the calendar, dictation, AirDrop, Caffeine, the screensaver, the apps, the keyboard and languages.

## The first minutes

- The computer starts into the lock screen. The first unlock after each start takes your password; after that, a fingerprint unlocks too, if you enrolled one.
- After your first unlock, the welcome sets what the installer could not, a page each, and only the pages that matter on your computer:
  - **Wi-Fi**, when the computer has a card and no connection, and on a laptop still on the cable it was installed on, for when it is not;
  - **Appearance**: the theme (a new account starts in white), and the background once there is more than one;
  - **Night Light**: on by hand, from sunset to sunrise, or at set hours;
  - **Apps**: Chrome and VS Code, when the install could not build them (an install without internet) and the computer is online now;
  - **Keyboard Shortcuts**: the few keys that lead to everything else.

  Continue passes a page by, and Return is Continue. Closing it, on any page, is the end of it; until then it comes back at each start. `nova welcome` opens it again.
- `nova help` lists every command, and `nova help <group>` one group's, such as `nova help theme`.

## Keys

Super+K searches every key and runs the one you pick. The tables below are the ones worth learning.

### Menus and apps

| Key | Does |
|---|---|
| Super+Space | the menu (the Copilot key too) |
| Super+Alt+Space | the apps |
| Super+Ctrl+C | the Capture menu |
| Super+Ctrl+O | the Toggle menu |
| Super+Escape | the System menu: lock, suspend, restart, shut down |
| Super+Ctrl+E | emojis |
| Super+Return | a terminal, in the focused terminal's directory |
| Super+Shift+Return, Super+Shift+B | the browser |
| Super+Shift+Alt+B | a private browser window |
| Super+Shift+F | Files |
| Super+Alt+Shift+F | Files, in the focused terminal's directory |
| Super+Shift+N | the editor |
| Super+Ctrl+T | Activity (btop) |

### Windows

| Key | Does |
|---|---|
| Super+W | close the window (windows have no title-bar buttons) |
| Ctrl+Alt+Delete | close every window |
| Super+arrows | focus the window that way |
| Super+Shift+arrows | swap the window that way |
| Alt+Tab, Alt+Shift+Tab | the next window, the one before |
| Super+T | floating or tiled |
| Super+F | full screen |
| Super+Ctrl+F | full screen within the tile |
| Super+Alt+F | full width |
| Super+O | pop the window out: floating, and pinned on every workspace |
| Super+J | split the other way |
| Super+L | this workspace's layout: dwindle or scrolling |
| Super+minus, Super+equals | resize the window across; with Shift, up and down; with Alt a little, with Ctrl a lot |
| Super+drag, Super+right-drag | move, resize |
| Super+G | group windows; Super+Alt+arrows move one into a group, Super+Alt+Tab goes through it |
| Super+Backspace | the window see-through or not |
| Super+Shift+Backspace | gaps between windows or none |

### Workspaces and displays

| Key | Does |
|---|---|
| Super+1 to Super+0 | workspace 1 to 10 |
| Super+Shift+1 to 0 | move the window there |
| Super+Shift+Alt+1 to 0 | move the window there, and stay here |
| Super+Tab, Super+Shift+Tab | the next workspace, the one before |
| Super+Ctrl+Tab | the workspace you were on |
| Super+S | the scratchpad; Super+Alt+S moves the window there |
| Super+Shift+Alt+arrows | move the workspace to the display that way |
| Ctrl+Alt+Tab | the next display |
| Super+slash, Super+Alt+slash | scale the display up, down |
| Super+Ctrl+Delete | the laptop's display on or off |
| Super+Ctrl+Alt+Delete | mirror the laptop's display, or stop |
| Super+Ctrl+Z, Super+Ctrl+Alt+Z | zoom in, back to normal |

The number keys, minus and equals are the same keys in every keyboard layout.

On a touchpad, three fingers sideways move to the workspace beside, which follows your fingers: left for the next one, right for the one before. The swipe goes through the workspaces of the display that have windows, as Super+Tab does, and stops at the first and the last.

### Screen capture and the clipboard

| Key | Does |
|---|---|
| Print | a screenshot |
| Alt+Print | a screen recording; again to stop |
| Super+Print | pick a color off the screen |
| Super+Ctrl+Print | copy the text in a region, by OCR (after `sudo pacman -S tesseract-data-eng`) |
| Super+C, Super+V, Super+X | copy, paste and cut in any window, a terminal too |
| Super+Ctrl+V | what was copied before, to paste again |

While you pick a region, Return takes the highlighted window, Ctrl+Return the whole screen, and Tab and the arrows move between windows.

### The desktop

| Key | Does |
|---|---|
| Super+Ctrl+L | lock |
| Super+D | dictation: hold and speak, or tap for hands-free; Esc cancels |
| Super+Ctrl+I | Caffeine |
| Super+Ctrl+N | night light |
| Super+Shift+Space | hide or show the bar |
| Super+Ctrl+Space | the background switcher |
| Super+Shift+Ctrl+Space | the theme menu |
| Super+comma | dismiss the last notification |
| Super+Shift+comma | dismiss every notification |
| Super+Ctrl+comma | do not disturb |
| Super+Alt+comma | open the last notification |
| Super+Shift+Alt+comma | the notification history |

### The bar's panels

| Key | Does |
|---|---|
| Super+Ctrl+A | sound |
| Super+Ctrl+B | Bluetooth |
| Super+Ctrl+W | network |
| Super+Ctrl+P | power |
| Super+Ctrl+D | display: brightness and the laptop's screen |
| Super+Ctrl+Alt+D | the clock's calendar |
| Super+Ctrl+Alt+W | the weather |
| Super+Ctrl+Alt+T | the time and date in a notification |
| Super+Ctrl+Alt+B | the battery's time left in a notification |
| Super+Ctrl+1 to 9 | the panels of the bar's right side, by place |

The volume, brightness, keyboard-light, touchpad and media keys work on the lock screen too. With Alt, volume and brightness move in finer steps; Shift+Mute switches to the next sound output.

### Changing a key

Your keys are in `~/.config/hypr/bindings.lua`. To change one of Nova's, unbind it and bind it again:

```lua
hl.unbind("SUPER + SPACE")
nova.bind("SUPER + SPACE", "Nova menu", "nova-menu toggle root")
```

The file has examples of a new key and of one removed.

## The menu

<img src="images/menu.jpg" alt="The Nova menu open in the middle of the screen: a search field, then Apps, Capture, Toggle, Style, Settings, Update and System" width="720">

Super+Space opens it. Type to search, or go down the list:

| Entry | Holds |
|---|---|
| Apps | the installed apps (Super+Alt+Space opens it here) |
| Capture | Screenshot; Screen Recording, without audio, with the desktop's or with the desktop's and the microphone's; Text, by OCR, once `tesseract-data-eng` is installed; Color; Emoji |
| Toggle | Caffeine, Do Not Disturb, Night Light, Screen Time, Menu Bar, Window Gaps; Laptop Display and Touchpad where there is one; Discrete GPU on a ThinkPad P1 Gen 4i |
| Style | Theme, Background, Font, and the Menu Bar's place and transparency |
| Power Mode | the battery's power modes, where the computer has them |
| Settings | Settings |
| Update | Nova and Firmware (Settings → Updates), Restart (the shell, audio, Wi-Fi or Bluetooth), Timezone, Password |
| System | Lock, Suspend, Hibernate (where the computer can), Log Out, Restart, Restart to Recovery, Shut Down |

Once a word of it has three letters, a search of the whole menu shows the files and folders in your home whose names match, below the rest. Return opens one with its app, and Ctrl+Return opens the folder it is in. Hidden folders, caches, `.git`, `node_modules` and drives mounted inside your home stay out, and so does anything more than five folders down. The search reads a list of your files, made again behind a search once it is five minutes old, so a new file shows from then; nothing lists them on a clock or as the menu opens.

`nova menu toggle <entry>` opens it at an entry, such as `nova menu toggle capture`. Entries in `~/.config/nova/menu.jsonc` override Nova's, key by key.

## The bar

By default the bar holds, from left to right: the menu's star and the workspaces; the indicators, the clock, the keyboard layout, the weather and the update badge; the tray, Bluetooth, mobile data, the network, sound and power.

- **Click** a widget for its panel. Click the star for the menu, right-click it for a terminal.
- **Drag** the bar by an empty part to another edge of the screen. Drag a widget to move it.
- **Double-click** an empty part for a [see-through bar](themes.md#a-see-through-bar), and again for a solid one.
- **Settings → Menu Bar** adds widgets and takes them off: Display for the brightness and the laptop's screen, Battery Life, Screen Time, Microphone, Media, Active window and more.

The bar's [own notes](../src/shell/plugins/bar/README.md) list every widget and what each click does.

## Settings

Settings opens from the menu, or with `nova settings <page>`. Asked for from another workspace than the one it is open on, it comes to yours, and so does the Calendar. A page shows only when the computer has what it needs: Wi-Fi, Bluetooth and Mobile Data need the radio, Battery a battery, and Performance power modes, a switchable discrete GPU or an Intel CPU.

| Page | What is on it |
|---|---|
| Wi-Fi | the radio on or off; the network in use, the known ones and the others |
| Bluetooth | the radio on or off; Bluetooth Low Energy, off for headphones that stutter; your devices and those nearby |
| Mobile Data | mobile data on or off, set up with the SIM's APN the first time; the SIM's PIN when it asks for one; the network, signal, address and data used this month |
| Notifications | [Do Not Disturb](#do-not-disturb), and the hours it holds by itself every day |
| Sound | the output and its volume; the input and its volume |
| Displays | each display's resolution, refresh rate, scale, rotation and place; a change goes back by itself after 15 seconds unless you keep it; the [night light](#night-light)'s schedule and warmth |
| Keyboard & Mouse | the keyboard's layouts, in order, and the keys that go to the next; the key repeat; the pointer's speed; natural scrolling with a mouse and on the touchpad, and tap to click |
| Battery | its measured life and history, its health, the charge limit, the lid and the power button, and when it hibernates |
| Performance | the power mode on battery, what the power manager is doing, the discrete GPU's mode, and the undervolt |
| Screen Time | on or off, and where your time went, per app; `nova screentime forget` deletes it |
| Appearance | the theme, the adaptive theme's mode, the background, the font and the text size ([themes](themes.md)) |
| Menu Bar | the bar's edge, see-through or not, and what is in it |
| Lock Screen | your password, the screensaver's and the lock's wait, and fingerprints |
| Default Apps | the web browser, the code editor and the terminal |
| Updates | Nova's and the apps' updates, device firmware, release candidates, Check for problems, a bug report and Restart to recovery ([updates](updates.md)) |
| About | the version, the computer, processor, memory, storage, name and kernel |

The page names for `nova settings` are `wifi`, `bluetooth`, `mobile-data`, `airdrop`, `notifications`, `sound`, `displays`, `keyboard`, `battery`, `performance`, `screentime`, `appearance`, `bar`, `lock`, `apps`, `updates` and `about`.

[Battery Life](../src/shell/plugins/batterylife/README.md), [Screen Time](../src/shell/plugins/screentime/README.md) and [Mobile Data](../src/shell/plugins/mobile-data/README.md) have notes of their own.

## Calendar

<img src="images/calendar.jpg" alt="The calendar showing a week in November 2026, with events on Friday, Saturday and Sunday and an empty task list beside it" width="720">

Events and tasks, in a week or a month. Open it from the clock's card, from a reminder, or with `nova calendar [week|month] [day]`, where the day is `2026-10-29`, `tomorrow` or `next friday`.

- **Events** move by dragging. An event's bottom edge, dragged, says when it ends; a drag over the empty hours makes a new one.
- **Tasks** go onto a day, onto a time (then they are reminded of), or off their day into the list beside.
- **Reminders** come as notifications. The clock in the bar dots the days with anything on them and lists what today has.
- **Keys:** the arrows step a week or a month, T is today, W and M the week and the month, N a new event, Esc closes.

It is one iCalendar file on your computer, `~/.local/share/nova/calendar/calendar.ics`, synced with nothing. The calendar's [own notes](../src/shell/plugins/calendar/README.md) have the rest.

## Dictation

Hold Super+D and speak: the words are pasted where the cursor is when you let go.

- A tap instead of a hold listens until the next press.
- Esc cancels.
- It hears you while you speak, a sentence at a time, so a long dictation is in as soon as you let go: at once if you stopped a moment before, in about a second if not. A pause to think in the middle of a sentence does not end it.
- "Uh", "um" and their Italian cousins are left out, and a word said twice by a stumble ("at at six") is written once.
- It runs on your computer, with NVIDIA's Parakeet, in 25 European languages. Nothing you say leaves it.
- The speech model, 669 MB, is downloaded once, at the first press, when you say yes.

`nova dictation` says whether it is ready.

## AirDrop

An iPhone can send photos, files and links to the computer with AirDrop, with nothing installed on it.

- Switch it on in the menu (Toggle → AirDrop) or with `nova airdrop on`, then pick the computer in the iPhone's share sheet.
- Or let your iPhone switch it: Settings → AirDrop → Let my iPhone turn on AirDrop. Tapping AirDrop in its share sheet then switches AirDrop on, and closing the sheet switches it off.
- A notification asks before anything is taken, as on a Mac: Accept or Decline. What arrives is in your downloads folder, and a notification with its picture opens it at a click.
- While AirDrop is on, the bar's Wi-Fi icon is AirDrop's.
- The Wi-Fi is off the network while AirDrop is on. It ends by itself, a moment after a transfer or after two minutes with none, and the Wi-Fi reconnects.

[AirDrop](airdrop.md) has the rest: why the Wi-Fi goes, which Wi-Fi cards can do it, and what it lets in.

## Caffeine

Caffeine keeps the screen on: no screensaver, no lock when unused, and on a laptop, closing the lid only turns the panel off, without sleeping, locking or dropping the network.

- Turn it on with Super+Ctrl+I, the menu's Toggle → Caffeine, `nova caffeine`, or the coffee cup among the bar's indicators beside the clock (they show when you point at the middle of the bar).
- It lasts until you turn it off or log out.
- On battery it also ends when the battery is down to 10%. A lid closed after that locks and sleeps.
- Lock and Suspend, chosen by hand, still lock and suspend.

## Night light

The night light makes the screen's colors warmer, for the evening.

- Switch it with Super+Ctrl+N, the menu's Toggle → Night Light, `nova toggle nightlight`, or its switch among the bar's indicators.
- **Settings → Displays** turns it on by itself: from sunset to sunrise, or at set hours every day. `nova nightlight schedule sunset` or `nova nightlight schedule 22:00 07:00` does the same.
- **Sunset and sunrise** are reckoned on the computer, with no network: for the weather's place, when it is set with its coordinates in the weather's card, else for the city the time zone is named for.
- It keeps to the clock through a sleep and a change of time zone.
- A switch by hand lasts until the next sunset or sunrise, or the next of the set hours. Turning the schedule off ends a night light it turned on, and leaves one you turned on.
- **Warmth**, on the same page or with `nova nightlight warmth 3400`, goes from 2500 K, the warmest, to 5500 K.

## Do Not Disturb

Do Not Disturb keeps notifications off the screen. What they say goes to the history (Super+Shift+Alt+comma).

- Switch it with Super+Ctrl+comma, the menu's Toggle → Do Not Disturb, or its switch among the bar's indicators.
- **Settings → Notifications** turns it on by itself at set hours every day. `nova notification schedule 22:00 07:00` does the same.
- A switch by hand lasts until the next of those hours. Turning the schedule off ends a Do Not Disturb it turned on, and leaves one you turned on. It keeps to the clock through a sleep and a change of time zone, and catches up with an hour that passed while the computer was off.
- It still lets through Nova's answers to what you just did, and urgent notifications sent by scripts (`notify-send -u critical`). Calendar reminders wait in the history.

## Screensaver and lock

- After three minutes unused, the screensaver plays the wordmark through text effects, in your theme's colors. After five, the screen locks.
- Settings → Lock Screen changes both waits, or turns them off.
- A key or the mouse ends the screensaver. `nova screensaver` shows it now.
- With a `~/.config/nova/screensaver.txt`, that text is played instead of the wordmark.
- An app that asks to keep the screen awake, through `org.freedesktop.ScreenSaver`, holds both off while it asks.

## Apps

These come installed:

| App | For |
|---|---|
| Chrome | the web |
| VS Code | code |
| Nautilus (Files) | files, phones, cameras and network shares |
| foot | the terminal |
| btop | Activity: what is running |
| Loupe, mpv | photos; video and music |
| Papers | PDFs and other documents |
| fastfetch | a summary of the system |
| Claude Code, Codex | coding agents in the terminal, through `mise` |

- Settings → Default Apps picks another browser, editor or terminal, among those installed.
- Chrome and VS Code are built on your computer from their AUR recipes; `nova apps install` installs them again if they are missing.
- Printing goes through CUPS: Print Settings is in the apps.
- **Quick Look**: in Files, Space shows the selected file, a picture, a video, a document or text, in a window the size of what it shows. Space again closes it.
- When a crash takes an app away, a notification says so ("Bambu Studio quit unexpectedly"), with Reopen. A crash that leaves its windows open, such as a browser tab's, is the app's own to show; `coredumpctl` lists them all.

## Keyboard

- **Caps Lock is the Compose key**: Compose, then `'`, then `e` types é.
- **Both Shifts together are Caps Lock**; the next Shift alone turns it off.
- **The layout** is the one picked at install. Settings → Keyboard & Mouse adds more, up to four, puts them in order and picks the keys that go to the next: Left Alt + Right Alt, Alt+Shift or Ctrl+Shift. The bar shows the layout in use while there are two or more, and a click goes to the next.
- **The login screen** types on the layout picked at install, whatever Settings has; the lock screen on the one in use.
- **A layout without Latin letters**, such as Russian or Greek, comes second to US, so the letter keys work; Left Alt + Right Alt switches between them. That US counts among the four.
- **The key repeat, the pointer's speed, the scrolling direction and tap to click** are on the same page, and `nova input` sets them too. What they set is kept over `~/.config/hypr/input.lua`, where the rest of Hyprland's input settings go.

On a touchpad, content follows your fingers, and one, two and three fingers click left, right and middle anywhere on it. Three fingers sideways go from workspace to workspace.

## Languages

Nova is in English. Text in other languages shows. Chinese, Japanese and Korean need `sudo pacman -S noto-fonts-cjk`, and have no input method yet.
