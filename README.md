# Screen Time

Where your time on this machine goes. A window you open from the Omarchy menu
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

## Requirements

Omarchy 4.0 or newer, and `jq` (already installed on Omarchy). Nothing else —
no daemon of its own, no systemd unit, no root.

## Install

```bash
omarchy plugin add https://github.com/Andre-cmd-rgb/omarchy-screentime.git --enable
```

Plugins run unsandboxed inside your shell process — read the code first.

Then add it to the Omarchy menu (Super+Space → Screen Time), and put the CLI
on your `PATH`:

```bash
~/.config/omarchy/plugins/andrecmdrgb.screentime/bin/screentime menu install
ln -sf ~/.config/omarchy/plugins/andrecmdrgb.screentime/bin/screentime ~/.local/bin/screentime
```

Counting starts immediately. The window has something to show after a minute.

## The three parts

| Part | What it does | Optional |
|---|---|---|
| service | counts seconds against the focused window, pauses when you are idle | no — this is the plugin |
| panel | the Screen Time window | opened on demand |
| bar widget | one glyph and today's total | yes — `screentime indicator off` |

Turning the indicator off only hides the glyph; the service keeps counting.
Disabling the *plugin* (`omarchy plugin disable`) stops everything.

## Using it

Open it from the Omarchy menu, from the bar indicator, or with `screentime
open`. Inside the window:

| Key | Does |
|---|---|
| `T` / `W` | today, or the last seven days |
| `←` `→` `Tab` | switch between them |
| `R` | refresh now |
| `Esc` | close |

Hovering a bar names the hour or the day and what it holds.

The window opens as an ordinary floating window. If your Hyprland setup tiles
it, float it with a rule:

```
windowrule = float, title:^(Screen Time)$
```

## What counts as time

A second counts when a window has focus and you are not idle. Idle is
`IDLE_TIMEOUT` seconds without input (three minutes by default), and when it
trips, the timeout itself is taken back off the app that had focus — otherwise
every trip to the kettle would bill three minutes to whatever was on screen.

An idle inhibitor counts as being here: a full-screen video keeps counting,
because watching it is time spent at the machine.

## CLI

```
screentime today [--short]     today's total and its busiest apps
screentime week [days]         a day-by-day breakdown (default 7)
screentime top [n]             today's busiest apps
screentime json [--days n]     everything the window draws
screentime open                open the window

screentime config [key]        show settings
screentime set <key> <value>   change one
screentime ignore <app-id>     never record an app again
screentime unignore <app-id>   undo that
screentime forget <app-id>     delete an app's history

screentime menu install|remove   add or remove the Super+Space entry
screentime indicator on|off      show or hide the bar indicator
```

## Settings

In `~/.config/omarchy-screentime/config`, or via `screentime set`:

| Key | Default | Meaning |
|---|---|---|
| `IDLE_TIMEOUT` | `180` | seconds without input before time stops counting |
| `FLUSH_INTERVAL` | `60` | seconds between writes to disk |
| `RETENTION_DAYS` | `90` | days of history to keep (`0` keeps everything) |
| `DAILY_GOAL` | `0` | daily limit in minutes; today's total turns red past it |
| `IGNORE` | — | comma-separated app ids never to record |

```bash
screentime set DAILY_GOAL 300
screentime ignore org.keepassxc.KeePassXC
```

An ignored app is not recorded at all, rather than hidden after the fact. Use
`screentime forget <app-id>` to drop what was recorded before you ignored it.

## Where the data lives

`~/.local/state/omarchy-screentime/days/YYYY-MM-DD.tsv`, one file per day,
three tab-separated columns: application id, hour of day, seconds. Plain text,
yours to read, edit, or delete:

```bash
rm -rf ~/.local/state/omarchy-screentime      # forget everything
```

Files older than `RETENTION_DAYS` are dropped on the first write of each day.

## Uninstall

```bash
screentime menu remove
omarchy plugin remove andrecmdrgb.screentime
rm -f ~/.local/bin/screentime
rm -rf ~/.config/omarchy-screentime ~/.local/state/omarchy-screentime
```

## License

MIT — see [LICENSE](LICENSE).
