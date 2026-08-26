# Changelog

## 1.4.0 — 2026-08-26

- `mobile-data profile [name]` shows or chooses the NetworkManager profile the
  plugin drives, checking that it exists and is a mobile connection. Moving off
  the profile `setup` happened to create previously meant editing the config
  file by hand, which is not a setting if you cannot set it.

## 1.3.0 — 2026-08-26

- A modem that has not come back yet is reported as `starting`, not `absent`.
  These M.2 modems do not survive a suspend — the MHI driver re-enumerates the
  module about thirty seconds after resume — and showing "No modem" beside an
  unlit switch for that half minute is what made mobile data look switched off
  when it never was.
- The switch reads as pending while that happens, so there is nothing to flip,
  and the widget polls every two seconds until the modem is back instead of
  leaving a stale glyph for up to ten.
- `on` waits for an activation NetworkManager has already started rather than
  raising a second one. A toggle during the resume window used to cancel
  NetworkManager's own attempt and start the clock again.
- No NetworkManager device at all is no longer reported as "NetworkManager is
  not managing the modem" — during the resume window there is simply no device
  yet, and only a device NM sees and refuses to drive is worth a warning.

## 1.2.0 — 2026-08-26

- `off` disconnects the device and clears the modem's bearers before blocking
  the radio. Cutting the radio out from under a live session leaves that
  session open inside the modem, and every connect afterwards answers `Busy` —
  a toggle that turns off and then will not turn back on.
- `on` gives the whole sequence one budget (`ON_TIMEOUT`, 90 s) instead of
  giving up after 25 s, waits for the modem to register before asking
  NetworkManager to activate anything, and retries within the budget after
  dropping any session the modem is still holding.
- Failures say what the modem was doing — no SIM, SIM locked, not registered
  yet, the network refused — instead of NetworkManager's "Unknown error", and
  the panel shows that line in the urgent colour instead of the switch quietly
  flicking back.
- New `mobile-data reset` to power-cycle a wedged modem, and `enable`/`disable`
  as aliases for `on`/`off`.
- A modem that is `enabled` but has not found a network is no longer reported
  as "registered".
- mmcli writes `--` where it has no value; `info` now reports those as empty
  instead of passing `operator=--` to the widget.

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
