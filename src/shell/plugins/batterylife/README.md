# Battery Life

Battery Life answers the one question the stock battery widget
cannot: **how long does this battery actually last?**

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

- **Left click** — the panel: time left, what a full charge buys at the rate
  you are drawing right now, and the power-profile switcher
- **Right click** — cycle the readout (time left → percent → watts → percent
  and watts → nothing)
- **Middle click** — straight to the history, in Settings

The popup has an IPC target of its own, so a keybind can reach it without
going through the bar:

```sh
nova-shell nova.batterylife.bar toggle
```

Battery Life records from the first boot, but its widget is not on the bar by
default: the stock power widget (`nova.power`) holds the battery slot, with the
power modes. To show this one beside it:

```sh
nova bar put nova.batterylife --after nova.power
```

The history is always in Settings → Battery.

## Its place in Settings

Settings → Battery, at the top: `nova battery open` or the bar widget opens it.

- **Today** — 24 columns, the average draw for each hour that ran on battery.
  An hour spent plugged in, asleep or switched off is drawn empty rather than
  as zero watts: those are different facts. Hover a column for the hour, how
  long of it ran on battery, and what it drew.
- **Week** — one column per day, the average draw for the time that day spent
  on battery.
- **Discharge runs** — every run long enough to mean something: when it
  started, the charge it spanned, how long it ran, and what it averaged.

## Starting with real numbers

UPower has been keeping its own history since long before this plugin was
installed. The files under `/var/lib/upower` are root-only, but the daemon
hands the same data to anyone over D-Bus:

```sh
nova battery import           # everything UPower still has
nova battery import --days 7  # just the last week
```

So a fresh install has a week of real runs in it rather than an empty chart.
Imported rows carry whole-percent charge readings, which is coarser than this
plugin's own samples — accurate to about 0.7 Wh on a 75 Wh pack. It averages
out over a run, which is why runs and averages are trustworthy from the start
while the minute-by-minute chart is smoother for runs recorded natively.

Importing never overwrites: rows already on disk always win, so it is safe to
run again.

## The CLI

Everything its page shows, and a few things it does not.

```
nova battery status [--short]     charge, draw, and time left
nova battery sessions [n]         past discharge runs and what they cost
nova battery health               capacity, wear, and cycle count
nova battery json [--days n]      everything its page draws

nova battery open [--week]        show it in Settings, under Battery
nova battery import [--days n]    seed history from UPower's own log

nova battery config [key]         show settings
nova battery set <key> <value>    change one
nova battery forget <date|all>    delete recorded history

nova battery indicator on|off     show or hide the bar entry
nova battery sample [--force]     record one reading (the shell runs it)
nova battery version
```

```
$ nova battery sessions
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
| `RESPONSE_SECONDS` | 60 | how fast the live estimate follows a change in load |

`RESPONSE_SECONDS` is the half-life of the weighting behind the live
estimate. Every interval counts for half as much as one `RESPONSE_SECONDS`
newer, so at the default the last minute decides the number and the ten
before it only damp the noise. Raise it for a steadier reading, lower it to
follow the machine more closely — though nothing can react faster than
`SAMPLE_INTERVAL`, since that is how often there is anything new to react to.

`GAP_SECONDS` is the one worth understanding. It is how the plugin tells a
suspend from a sample it simply missed. Too low and a busy moment that
delayed a sample looks like time the machine was off; too high and a short
nap counts as runtime. Five minutes is five missed samples.

## What is stored

`~/.local/state/nova-batterylife/days/YYYY-MM-DD.tsv`, one row per sample:

```
epoch  state  percent  energy_uWh  full_uWh  power_uW
```

Charge, draw and capacity. Nothing about what the machine was doing at the
time, and nothing that leaves the machine. `nova battery forget all` deletes
the lot.

## Charging

The same machinery runs in both directions. Time-to-full is measured from the
charge actually going in, not from the instantaneous reading, and the watts on
screen are the fill rate — never the average of the discharge runs behind it,
which is a number about a different thing entirely.

While charging there is no drain to project from, so the full-charge figure
steps aside rather than quoting a stale one. "Not charging" — plugged in but
taking nothing, which is what a charge threshold looks like — gets the plain
level glyph rather than a bolt, because no current is flowing.

## Tests

```sh
bash test/roundtrip.sh
```

51 checks against a fake battery and a written history, in a temporary tree —
the real machine is never touched. That is what makes the awkward cases
testable: a battery cannot be asked to be at 3% and charging on demand, and a
suspend cannot be arranged to order. Covered: energy- and charge-reporting
batteries, device batteries being skipped, the sampling floor, run detection
across a suspend and across a charge, the charging path, retention, settings
validation, and an empty history still producing valid JSON.

## Turning it off

Battery Life is on from the first boot. `nova bar remove nova.batterylife`
takes its widget off the bar; to stop the recording as well, add
`"nova.batterylife"` to `disabledPlugins` in `~/.config/nova/shell.json`.
`nova battery forget all` deletes what it recorded.
