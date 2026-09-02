# Changelog

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
