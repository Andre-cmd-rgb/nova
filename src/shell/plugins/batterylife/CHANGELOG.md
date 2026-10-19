# Changelog

## Unreleased

- **The bar widget refreshes when something changes, instead of every two
  minutes.** It was never receiving the service's `sampled()` signal: the host
  injects `service` into *panel* loaders only, and `Bar.qml`'s `injectProps`
  sets `bar`, `moduleName` and `settings` and nothing else — so the property
  stayed null, the `Connections` block bound to nothing, and the "every sample
  is a free refresh" path never ran once. The widget looks the service up
  through the bar's own shell reference now.
  - Resolved rather than bound, because `serviceFor` is a plain function call
    and the first answer is `null`: measured on this machine, the widget asks
    once before the host has built its services and once after.
- **Charge and state come from UPower and are live.** They were waiting on the
  record, which moves at the sampler's cadence — a minute on battery, five on
  AC — so the glyph and the percentage could be that far behind. Everything
  *measured* still comes from the CLI, so the panel and the terminal cannot
  disagree. (`percentage` is 0..1 there, which is the trap in it.)
- A read now also happens on each whole percent, on any state change, and on
  the plug going in or out — that last one used to keep the old source's
  estimate for up to two minutes. The timer behind them drops 120 s → 60 s and
  is a net rather than the mechanism; concurrent reads are already suppressed
  by the `jsonProc.running` guard, so the added triggers cost no extra forks.
- Clicking the widget takes a fresh sample even when the service failed to
  load, via a direct call to the CLI. Safe by construction: the CLI keeps a
  15 s floor between rows in the same state, so a redundant sample is a no-op
  rather than a duplicate row skewing the averages behind it.

## 1.0.0 — 2026-09-02

First release.

- Records charge, draw and capacity every minute on battery and every five
  minutes on AC, and turns them into discharge runs with a measured duration.
- Battery Life window: today hour by hour, a per-day average for the week,
  and every run long enough to mean something.
- Bar widget with a measured time-left readout, right-click to cycle what it
  shows. Takes the stock power widget's slot with `batterylife takeover on`.
- `batterylife import` seeds the history from UPower's own log, so a fresh
  install has a week of real runs rather than an empty chart.
- Time left follows the machine: intervals are weighted by age, halving every
  `RESPONSE_SECONDS`, so a terminal and a video read differently within a
  minute of each other.
- Charging is measured the same way as discharging — time-to-full comes from
  the charge going in, and the watts shown are the fill rate.
- `batterylife` CLI owns storage, settings and the reports.
- `bash test/roundtrip.sh` — 49 checks against a fake battery.
