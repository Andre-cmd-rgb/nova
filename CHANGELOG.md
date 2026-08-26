# Changelog

## 1.1.0 — 2026-08-26

- Latency is now the median of the window rather than its mean. One slow sample
  used to drag the average for five ticks, so the number appeared to settle
  downwards over the following seven seconds instead of being right at once.
- Throughput and latency are sampled while the panel is closed too, so it opens
  on numbers that are already there.
- New `backgroundStats` setting (default on) to turn that off: it costs about
  1.5 MB a day in echo traffic and wakes the radio on the poll cadence.
- The latency window is dropped when the link goes down, so a reconnect never
  shows a number measured before the outage.

## 1.0.0 — 2026-08-26

First public release, renamed from the personal `andre.mobile` plugin.

- Plugin id is now `andrecmdrgb.mobile-data`; the helper CLI is `mobile-data`.
- Config moved to `~/.config/omarchy-mobile-data/config` and state to
  `~/.local/state/omarchy-mobile-data/`. The old `~/.config/omarchy/mobile.conf`
  and `~/.local/state/omarchy-mobile/` are copied forward on first run, so the
  billing period and profile setting survive the rename.
- Poll interval is declared in the manifest, so the settings panel can offer it.
- `nmcli`, `mmcli`, `rfkill`, `ip` and `ping` are pinned to the C locale; their
  state words are matched in English and a translated desktop used to read as
  "no modem".
- Config writes go through `awk` instead of a `sed` replacement, so an APN
  containing `&` or `\1` is written literally.
- `mobile-data version`, and a real `--help` instead of an excerpt of the file's
  own header.
