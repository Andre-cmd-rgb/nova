# Changelog

## 1.0.0 — 2026-08-26

First release.

- Counts focused-application time inside the Nova shell, pausing on idle.
- Screen Time window with a per-hour chart of today, a per-day chart of the
  week, and the applications behind them.
- Optional single-glyph bar indicator.
- `screentime` CLI owns settings, history, and the reports.
- The shell's own windows (`org.quickshell`) are ignored by default.
- Applications are shown by name rather than by window id, resolved from the
  desktop entries on the machine, from Steam's manifests for `steam_app_*`
  games, and from the domain of a Chrome web app. `screentime names` lists
  what each id resolved to and `screentime name` pins a different one.
