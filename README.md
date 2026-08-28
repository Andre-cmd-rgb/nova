# omarchy-boot-theme

Omarchy themes everything from the login screen inwards. It does not theme the
two things you actually see first.

- **Limine**, the boot menu, is never themed at all. `limine-entry-tool` owns
  the `/entry` blocks in `limine.conf` and leaves the global options — which is
  where the colours live — alone.
- **Plymouth**, the boot splash, is themed only when you pick an unlock screen
  by hand from `Super+Space → Style → Unlock`. Nothing re-runs it when the
  theme changes.

So they drift. On the machine this was written for, the splash background was
`#faf4ed` (Rose Pine Dawn), the console log colour was `0x1a1b26`
(Tokyo Night), and the active theme was White.

This puts both on the current theme, and keeps them there.

## Install

```
./install.sh
```

Installs `omarchy-boot-theme` and `omarchy-limine-theme` into `~/.local/bin`
and adds an Omarchy `theme-set` hook, so every theme change re-themes the boot
path. `--no-hook` installs the commands only; `--uninstall` removes both and
restores `limine.conf`.

Then apply it to the theme you are on:

```
omarchy-boot-theme
```

## Use

```
omarchy-boot-theme [theme-slug]        both halves (default: current theme)
omarchy-boot-theme --limine  [slug]    boot menu only, no initramfs rebuild
omarchy-boot-theme --plymouth [slug]   splash and login screen only
```

Both halves need root, so the commands call `sudo`. The hook runs them in a
floating terminal — the same one Omarchy's own menu entries use — so there is
somewhere to type the password.

**The Plymouth half rebuilds the initramfs, which takes about a minute.** If
you browse themes a lot, edit the installed hook at
`~/.config/omarchy/hooks/theme-set.d/omarchy-boot-theme` to pass `--limine`,
and re-theme the splash when you have settled.

Neither half changes anything you can see right now. Restart to see them.

## What it changes

| Where | What |
|---|---|
| `/boot/limine.conf` | a marked block of global colour options, above the first entry |
| `/usr/share/plymouth/themes/omarchy/` | background, logo and asset colours (via `omarchy-plymouth-set`) |
| `/usr/share/sddm/themes/omarchy/` | the same colours and logo, so boot and login agree |
| `~/.config/omarchy/hooks/theme-set.d/` | the hook that re-runs this on a theme change |

The Plymouth and SDDM halves are entirely Omarchy's own
`omarchy-plymouth-set-by-theme`; this only calls it at the right moment. The
Limine half is the new part.

Colours come from the theme's `colors.toml`: `background` and `foreground` for
the terminal and backdrop, `accent` for the branding, and the six ANSI colours
for `term_palette`. A theme missing `background` or `foreground` is refused
rather than half-applied.

## Safety

`limine.conf` decides whether the machine boots, so `omarchy-limine-theme`:

- writes only between its own markers, and replaces that block rather than
  appending to it,
- puts the block **above the first `/` entry** — a global option after an entry
  belongs to that entry instead, which would silently not work,
- copies the original to `limine.conf.omarchy-limine-theme.bak` on first run,
- refuses a `limine.conf` with no menu entries, and refuses to install a
  rewrite that changed the entry count.

`test/limine.sh` drives all of that against a fixture rather than against
`/boot`, including the refusals.

If the boot menu is ever wrong, any Limine entry still boots — the colours are
cosmetic — and the original is at `/boot/limine.conf.omarchy-limine-theme.bak`.

## Tests

```
./test/limine.sh
```
