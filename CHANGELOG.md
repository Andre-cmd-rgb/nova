# Changelog

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
