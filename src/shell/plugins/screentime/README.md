# Screen Time

Where your time on this machine goes. A window you open from the Nova menu
with an hour-by-hour breakdown of today, a day-by-day chart of the week, and
the applications that account for it — plus an optional one-glyph indicator in
the bar.

```
 SCREEN TIME                           ┌───────┬──────┐
 3h 42m                                │ Today │ Week │
 today · 5h limit                      └───────┴──────┘

   ▁ ▁ ▂ ▅ █ ▆ ▃ ▂ ▁ ▁ ▄ ▇ █ ▅ ▂ ▁ ▁ ▃ ▆ █ ▄ ▁ ▁ ▁
   0           6          12          18

 MOST USED
 Chromium                                       1h 20m
 ████████████████████████████████████████░░░░░░░░░░░░
 Alacritty                                         55m
 ███████████████████████████░░░░░░░░░░░░░░░░░░░░░░░░░
 Zed                                               41m
 ████████████████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
```

Everything stays on this machine. Only the application id, the hour it was
used in, and a count of seconds are ever written down — never window titles,
never file names, never anything about what you were doing in an app.

## Turning it on

Screen Time is off until you turn it on, and records nothing before that:

```bash
nova screentime on        # or Super+Space → Toggle → Screen Time
```

It then appears in the bar and in the menu (Super+Space → Screen Time) and
counts from that moment. `nova screentime off` stops it; what it recorded
stays until you delete it (see below).

## The three parts

| Part | What it does | Optional |
|---|---|---|
| service | counts seconds against the focused window, pauses when you are idle | no — this is the plugin |
| panel | the Screen Time window | opened on demand |
| bar widget | one glyph and today's total | yes — `nova screentime indicator off` |

Turning the indicator off only hides the glyph; the service keeps counting.
`nova screentime off` stops everything.

## Using it

Open it from the Nova menu, from the bar indicator, or with `screentime
open` (`nova screentime open --week` lands on the weekly view; a summon payload of
`{"range":"week"}` does the same from a menu entry or a keybinding). Inside the
window:

| Key | Does |
|---|---|
| `T` / `W` | today, or the last seven days |
| `←` `→` `Tab` | switch between them |
| `R` | refresh now |
| `Esc` | close |

Hovering a bar names the hour or the day and what it holds.

The window is an ordinary toplevel, so Hyprland tiles it by default. Nova
configures Hyprland in Lua — add this to the bottom of
`~/.config/hypr/hyprland.lua` to have it arrive floating, centred, and opaque:

```lua
o.window({ class = "^org\\.quickshell$", title = "^Screen Time$" }, {
  float = true,
  center = true,
  size = { 620, 720 },
  -- A chart read through the window behind it is not a chart.
  tag = "-default-opacity",
  opacity = "1 1",
})
```

Then `hyprctl reload`.

## What counts as time

A second counts when a window has focus and you are not idle. Idle is
`IDLE_TIMEOUT` seconds without input (three minutes by default), and when it
trips, the timeout itself is taken back off the app that had focus — otherwise
every trip to the kettle would bill three minutes to whatever was on screen.

An idle inhibitor counts as being here: a full-screen video keeps counting,
because watching it is time spent at the machine.

## What the apps are called

A window only tells the shell its application id — `org.gnome.Nautilus`,
`steam_app_387990`, `xdg-desktop-portal-gtk` — so the id is looked up before
anything is shown:

| Id | Shown as | From |
|---|---|---|
| `org.gnome.Nautilus` | Files | its desktop entry |
| `google-chrome` | Google Chrome | its desktop entry |
| `steam_app_387990` | Scrap Mechanic | Steam's own manifest for the game |
| `chrome-youtube.com__-Default` | YouTube | the desktop entry of the web app it opens, or failing that its domain |
| `xdg-desktop-portal-gtk` | System Dialog | a built-in rule — this is every file chooser and screen-share prompt |
| anything unknown | `Foo Bar` from `foo-bar` | a guess at the id |

`nova screentime names` lists every id in your history next to the name it is shown
under. When one of them is wrong or unhelpful, pin your own:

```bash
nova screentime names
nova screentime name hyperwriter-shot "Hyperwriter (screenshot)"
nova screentime name hyperwriter-shot --reset      # back to the detected name
```

Pinned names live in `~/.config/nova-screentime/names` as
`app-id=Display Name`, one per line, and are yours to edit directly. They
rename what you see; the history is still keyed by the app id, so pinning,
renaming and resetting never touch the numbers.

## CLI

```
nova screentime today [--short]     today's total and its busiest apps
nova screentime week [days]         a day-by-day breakdown (default 7)
nova screentime top [n]             today's busiest apps
nova screentime json [--days n]     everything the window draws
nova screentime open                open the window

nova screentime config [key]        show settings
nova screentime set <key> <value>   change one
nova screentime names               every app id and the name it is shown under
nova screentime name <id> [name]    show that name, or pin your own
nova screentime ignore <app-id>     never record an app again
nova screentime unignore <app-id>   undo that
nova screentime forget <app-id>     delete an app's history

nova screentime indicator on|off      show or hide the bar indicator
```

## Settings

In `~/.config/nova-screentime/config`, or via `nova screentime set`:

| Key | Default | Meaning |
|---|---|---|
| `IDLE_TIMEOUT` | `180` | seconds without input before time stops counting |
| `FLUSH_INTERVAL` | `60` | seconds between writes to disk |
| `RETENTION_DAYS` | `90` | days of history to keep (`0` keeps everything) |
| `DAILY_GOAL` | `0` | daily limit in minutes; today's total turns red past it |
| `IGNORE` | `org.quickshell` | comma-separated app ids never to record |

Display names are not settings — they live in their own file, see
[What the apps are called](#what-the-apps-are-called).

```bash
nova screentime set DAILY_GOAL 300
nova screentime ignore org.keepassxc.KeePassXC
```

An ignored app is not recorded at all, rather than hidden after the fact. Use
`nova screentime forget <app-id>` to drop what was recorded before you ignored it.

`org.quickshell` is ignored out of the box: the Nova menu and this plugin's
own window are shell surfaces, not applications you spend time in. Setting
`IGNORE` yourself replaces that default — include it if you still want it.

## Where the data lives

`~/.local/state/nova-screentime/days/YYYY-MM-DD.tsv`, one file per day,
three tab-separated columns: application id, hour of day, seconds. Plain text,
yours to read, edit, or delete:

```bash
rm -rf ~/.local/state/nova-screentime      # forget everything
```

Files older than `RETENTION_DAYS` are dropped on the first write of each day.

`~/.local/state/nova-screentime/names.tsv` sits beside them: resolved
display names, cached so the panel does not re-read every desktop entry on the
machine each time it refreshes. Deleting it costs nothing.

## Forgetting everything

```bash
nova screentime off
rm -rf ~/.config/nova-screentime ~/.local/state/nova-screentime
```
