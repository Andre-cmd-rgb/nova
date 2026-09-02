# Battery Life

An Omarchy shell plugin that answers the one question the stock battery
widget cannot: **how long does this battery actually last?**

The built-in readout is an instantaneous estimate. It divides the charge left
by whatever the battery happens to be drawing at the moment you look, so it
swings by hours between two glances at the same idle desktop, and it forgets
everything the second you plug in. There is no record, so there is no way to
tell whether anything you changed helped.

This keeps the record. Every discharge run is measured — how long it lasted,
how much charge it cost, what that works out to per hour — and the projection
you get is built from your own last two weeks rather than from the last five
seconds.

```
BATTERY LIFE
3h 41m
a full charge at 20.2 W  ·  measured over 21 runs
```

## What it measures

Two clocks run over every discharge run, and they answer different questions:

| | |
|---|---|
| **elapsed** | end minus start — "the battery went from 09:00 to 19:30" |
| **runtime** | the gaps between samples, counting only gaps short enough to have been sampled through |

A suspended laptop adds to the first and not to the second. That is the whole
point: a machine that spent the night asleep should not wake up claiming
fourteen hours of battery life. Runtime is time the machine was actually on.

Energy is summed the same way, so watts always divide energy that was
measured over time that was measured — never one over the other.

Charge is read as **energy** (`energy_now`, in watt-hours) rather than
integrated from the power draw. That is what makes a suspend survivable: a
reading taken before and one taken after tell you exactly what it cost,
however long the machine was away and however few samples there are either
side. Integrating the draw would lose the lot.

## The bar

A battery glyph and, by default, the time left — measured from your own
recent draw rather than the instantaneous rate, so it does not jump around.
The glyph is drawn at the bar's icon size and the readout at its label size,
so it sits level with the status glyphs on one side and the text widgets on
the other.

- **Left click** — the panel: time left, this run, and what a full charge buys
- **Right click** — cycle the readout (time left → percent → watts → percent
  and watts → nothing)
- **Middle click** — straight to the history window

The popup has an IPC target of its own, so a keybind can reach it without
going through the bar:

```sh
omarchy-shell andrecmdrgb.batterylife.bar toggle
```

To take the stock power widget's slot:

```sh
batterylife takeover on     # put this one where omarchy.power was
batterylife takeover off    # give it back
```

`takeover on` moves this widget immediately after the stock one and then
disables the stock one, which leaves this widget exactly where that one was.
`takeover off` re-enables the stock widget and puts it back beside this one —
`omarchy plugin enable` alone would drop it in the centre, since the stock
power widget declares no section of its own.

Both are safe to run twice. There is no command that takes a widget off the
bar without disabling its plugin, so `takeover off` leaves this one in place;
disabling the plugin would also stop it recording.

Power profiles remain on the Omarchy menu under Super+Space.

## The window

`batterylife open`, the bar widget, or Super+Space → Battery Life.

- **Today** — 24 columns, the average draw for each hour that ran on battery.
  An hour spent plugged in, asleep or switched off is drawn empty rather than
  as zero watts: those are different facts. Hover a column for the hour, how
  long of it ran on battery, and what it drew.
- **Week** — one column per day, the average draw for the time that day spent
  on battery.
- **Discharge runs** — every run long enough to mean something: when it
  started, the charge it spanned, how long it ran, what it averaged, and what
  that implies for a full battery.

`T` today · `W` week · `R` refresh · `Esc` close.

The window is a floating one. Hyprland tiles it by default, so it wants a
rule of its own — the same one Screen Time uses:

```lua
o.window({ class = "^org\\.quickshell$", title = "^Battery Life$" }, {
  float = true,
  center = true,
  size = { 620, 720 },
  tag = "-default-opacity",
  opacity = "1 1",
})
```

## Starting with real numbers

UPower has been keeping its own history since long before this plugin was
installed. The files under `/var/lib/upower` are root-only, but the daemon
hands the same data to anyone over D-Bus:

```sh
batterylife import           # everything UPower still has
batterylife import --days 7  # just the last week
```

So a fresh install has a week of real runs in it rather than an empty chart.
Imported rows carry whole-percent charge readings, which is coarser than this
plugin's own samples — accurate to about 0.7 Wh on a 75 Wh pack. It averages
out over a run, which is why runs and averages are trustworthy from the start
while the minute-by-minute chart is smoother for runs recorded natively.

Importing never overwrites: rows already on disk always win, so it is safe to
run again.

## The CLI

Everything the window shows, and a few things it does not.

```
batterylife status [--short]     charge, draw, and time left
batterylife sessions [n]         past discharge runs and what they cost
batterylife health               capacity, wear, and cycle count
batterylife json [--days n]      everything the window draws

batterylife open [--week]        open the Battery Life window
batterylife import [--days n]    seed history from UPower's own log

batterylife config [key]         show settings
batterylife set <key> <value>    change one
batterylife forget <date|all>    delete recorded history
```

```
$ batterylife sessions
STARTED           CHARGE     RUNTIME   DRAW     FULL CHARGE
Tue 01 Sep 23:32   99% → 37 %  2h 02m    22.0 W   3h 23m
Tue 01 Sep 15:48   99% → 7  %  2h 09m    29.4 W   2h 32m
Tue 01 Sep 02:01   99% → 57 %  1h 27m    20.3 W   3h 39m
```

## Settings

| Key | Default | |
|---|---|---|
| `SAMPLE_INTERVAL` | 60 | seconds between samples while on battery |
| `AC_INTERVAL` | 300 | seconds between samples while plugged in |
| `RETENTION_DAYS` | 180 | days of history to keep (0 keeps everything) |
| `GAP_SECONDS` | 300 | a quiet stretch longer than this counts as suspended |
| `MIN_SESSION` | 600 | ignore discharge runs shorter than this |
| `TYPICAL_DAYS` | 14 | days averaged into the full-charge projection |

`GAP_SECONDS` is the one worth understanding. It is how the plugin tells a
suspend from a sample it simply missed. Too low and a busy moment that
delayed a sample looks like time the machine was off; too high and a short
nap counts as runtime. Five minutes is five missed samples.

## What is stored

`~/.local/state/omarchy-batterylife/days/YYYY-MM-DD.tsv`, one row per sample:

```
epoch  state  percent  energy_uWh  full_uWh  power_uW
```

Charge, draw and capacity. Nothing about what the machine was doing at the
time, and nothing that leaves the machine. `batterylife forget all` deletes
the lot.

## Requirements

Omarchy shell, `jq`, and `busctl` (systemd) for the optional import. The
sampler runs inside the shell; the CLI needs nothing but a battery and works
from a TTY.

## Install

```sh
omarchy plugin add https://github.com/Andre-cmd-rgb/omarchy-batterylife --enable
batterylife import
batterylife takeover on
```

## License

MIT.
