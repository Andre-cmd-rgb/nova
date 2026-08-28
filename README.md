# omarchy-boot-theme

Omarchy themes everything from the login screen inwards. The two things you
actually see first are another matter.

- **Limine**, the boot menu, is not themed from your theme at all. Omarchy
  ships its own `limine.conf` with the Tokyo Night palette written into the
  global options and installs it to the ESP, and `limine-entry-tool` only ever
  touches the `/entry` blocks below it. So the boot menu is Tokyo Night on
  every theme, forever.
- **Plymouth**, the boot splash, is themed only when you pick an unlock screen
  by hand from `Super+Space → Style → Unlock`, and even then it paints a flat
  background colour with the theme's `unlock.png` centred on it. It never shows
  the wallpaper you picked.
- **SDDM**, the login screen, gets a **black background on any theme whose
  background is `#ffffff`** — an upstream bug, see below.

- **The splash goes away before the login screen arrives.** `plymouth quit`
  hides the splash and blanks the screen, and `sddm.service` is ordered *after*
  it, so there is a black gap between the two while the greeter starts.

This puts the boot menu on your theme's colours, puts your current wallpaper
behind the splash, gives the login screen a plain themed background, holds the
splash on screen across the handoff, and keeps all of it there.

## Install

```
./install.sh
```

Then apply it to the theme and wallpaper you are on:

```
omarchy-boot-theme
```

`--no-hook` installs the commands only; `--uninstall` removes everything and
restores `limine.conf`.

## Use

```
omarchy-boot-theme [theme-slug]        everything (default: the current theme)
omarchy-boot-theme --limine  [slug]    boot menu only, no initramfs rebuild
omarchy-boot-theme --plymouth [slug]   splash and login screen only
omarchy-boot-theme --wallpaper         splash wallpaper only, one rebuild
```

**The splash lives in the initramfs, so changing it costs a rebuild of about a
minute.** A theme change pays for two: Omarchy's own `omarchy-plymouth-set`
rebuilds once for the colours, and rewrites the Plymouth script and `Main.qml`
from its defaults while doing it, so the wallpaper has to be put back and
rebuilt again. A wallpaper change pays for one. Nothing happens at all when
nothing changed — see *Doing nothing* below.

Neither half changes anything you can see right now. Restart to see them.

## What it changes

| Where | What |
|---|---|
| `/boot/limine.conf` | a marked block of global colour options, with the competing ones commented out |
| `/usr/share/plymouth/themes/omarchy/` | `background.png`, and a marked block appended to `omarchy.script` |
| `/usr/share/sddm/themes/omarchy/` | a regenerated `Main.qml` |
| `~/.config/omarchy/hooks/theme-set.d/` | re-runs this on a theme change |
| `/etc/boot/hooks/post.d/50-omarchy-boot-theme` | re-applies the menu colours whenever `limine.conf` is regenerated |
| `/etc/systemd/system/omarchy-splash-wallpaper.{path,service}` | re-applies the splash wallpaper whenever you change the wallpaper |
| `/etc/systemd/system/plymouth-quit.service.d/omarchy-boot-theme.conf` | keeps the splash on screen until the login screen paints |

Colours come from the theme's `colors.toml`: `background` and `foreground` for
the terminal and backdrop, `accent` for the branding and help text, and the six
ANSI colours for `term_palette`. A theme missing `background` or `foreground` is
refused rather than half-applied.

## The boot menu was the default colours

The first version of this appended its colours to `limine.conf` and reported
success, and the boot menu stayed Tokyo Night. Two things were wrong.

**Omarchy writes its own colours, and they were above ours.** Not
`limine-entry-tool` — Omarchy itself, in `default/limine/limine.conf`:
`term_background: 1a1b26`, `backdrop: 1a1b26`, a full Tokyo Night
`term_palette`. **Limine honours the first definition of a duplicated global
key and ignores the rest**, so a block further down the file parses and then
loses. Adding colours was never going to be enough; the existing ones have to
stop being definitions. Every global colour option above the first entry is now
commented out with a `#omarchy-limine-theme:superseded#` prefix — commented, not
deleted, so the original value stays readable and recoverable — and ours are
written in one block. The tool then asserts there is exactly **one live
definition of each** before it installs anything.

**`colour` and `color` are the same option.** Omarchy writes
`interface_branding_color`; we wrote `interface_branding_colour`. Limine accepts
either, so a key-by-key match that treats them as different keys leaves a live
duplicate above ours — which is the entire bug, one alias down. They are
matched as one option, and the test suite checks that pair specifically.

Everything Omarchy set is set again, rather than only the four values the first
version wrote. Commenting out `interface_help_color` without replacing it does
not leave the help text unthemed, it leaves it on Limine's built-in default —
green, on a white menu.

## The splash was a logo, and the login screen was black

Two different problems that looked like one.

**The splash.** `omarchy-plymouth-set` paints the window a flat `background`
colour and centres the theme's `unlock.png` on it. On the White theme that is
the pink circle-square-diamond on white: working exactly as designed, and
nothing to do with your wallpaper. `background.png` is now rendered from
`current/background` at your screen's native resolution and drawn behind
everything at z `-100`, and the logo sprite is hidden rather than removed —
`entry.y` is measured from it, so deleting it would move the password field.

**The login screen.** This one is an upstream bug. `omarchy-plymouth-set`
substitutes the SDDM template's colours with two sequential seds:

```bash
sed -e "s/#1a1b26/#$bg_hex/g" -e "s/#ffffff/#$text_hex/g"
```

On a theme whose `background` is `#ffffff`, the first expression writes that
value into the template's `color: "#1a1b26"` and the second expression then
rewrites the string it just wrote to the *foreground* colour. The White theme
gets `color: "#000000"` — a black login screen, on a fully white theme. The
substitution here goes through placeholders, so neither expression can see the
other's output, and `Main.qml` is regenerated from the upstream template with
the logo block dropped.

**The login screen does not get the wallpaper.** It did at first, and it was
wrong: the password box sits in the centre of the screen, which is exactly
where a wallpaper puts its branding, so the two landed on top of each other.
The login screen gets the theme's `background` as a flat colour and nothing
else — the password box alone on it. The root `Rectangle` was always going to
paint that colour anyway; dropping the image just stops covering it up.

The in-session lock screen (`Super+Escape`) already uses your wallpaper,
blurred, in `shell/plugins/lock/LockView.qml`. It was never the problem — the
screen you saw was SDDM.

## Doing nothing

The wallpaper watch fires on every wallpaper change, and plenty of those change
nothing that matters. Since the cost of being wrong is a minute of `mkinitcpio`,
`omarchy-splash-wallpaper` exits early unless something really did change — and
it checks the installed state, not just its own stamp: `background.png` present,
its marked block still in `omarchy.script`, its marker still in `Main.qml`, and
the stamp matching the theme, the wallpaper's `sha256` and the screen geometry.
`omarchy-plymouth-set` rewrites both of those files from Omarchy's defaults
whenever anyone sets an unlock style by hand, which would otherwise leave the
stamp claiming to be current over a splash that had quietly reverted.

A wallpaper that renders to more than 4MB gets rendered smaller instead, in 30%
steps. It goes into the initramfs, and a soft splash beats a boot image that
doubled in size. On this machine the wallpaper renders to 37KB, so the cost is
nothing; a photograph is what the cap is there for.

## Four things the verification pass caught

None of these showed up in normal use, and all four would have.

**A GIF wallpaper produced no wallpaper.** `omarchy-theme-bg-set` takes any
image, and ImageMagick writes *one numbered file per frame* for a multi-frame
input — `background-0.png`, `background-1.png` — so `background.png` was never
created and the run failed on a perfectly valid wallpaper. The frame is now
selected explicitly, with `[0]`.

**systemd would have killed the rebuild.** `Type=oneshot` inherits
`DefaultTimeoutStartUSec`, which is **90 seconds** on this machine, and a
`limine-mkinitcpio` run is about that long. The service would have been sent
`SIGTERM` partway through writing the initramfs this machine boots from. It now
sets `TimeoutStartSec=1800`, and `RequiresMountsFor=/boot` because that is where
it writes.

**`RequiresMountsFor=` was in the wrong section.** It belongs in `[Unit]`, and
it was in `[Service]`, where systemd ignores it — `Unknown key
'RequiresMountsFor' in section [Service], ignoring.` in the journal. Caught by
reading the journal after the first live run rather than by any test, which is
the argument for reading the journal after the first live run.

**`-alpha remove` is wrong on this ImageMagick.** A wallpaper with transparency
has to be flattened onto the theme's background — ImageMagick's own default is
white, which is wrong on every dark theme. But on ImageMagick 7.1.2,
`-background '#1a1b26' -alpha remove` returns `srgb(26,26,26)`: it keeps the red
channel and greys the other two. `-flatten` with the same background correctly
returns `srgb(26,27,38)`. A transparent wallpaper on Tokyo Night came out grey.
There is a test asserting the exact pixel.

## Why three hooks

The `theme-set` hook covers you changing the theme. The
`omarchy-splash-wallpaper.path` unit covers you changing the wallpaper — nothing
in Omarchy runs a hook for that, so it watches the `current/` directory rather
than the `background` symlink inside it: `omarchy-theme-bg-set` swaps the link
with `ln -nsf`, and an inotify watch on a symlink follows it to its target and
would report changes to the image file while missing every change of *which*
image it is.

The Limine hook covers everything that rewrites `limine.conf` behind your back
— a kernel update, `mkinitcpio`, a snapshot sync — any of which would otherwise
drop the colour block and quietly revert the boot menu. `limine-entry-tool` runs
`/etc/boot/hooks/post.d/*` after each such regeneration.

The number in `50-omarchy-boot-theme` is deliberate. `90-limine-enroll-config`
enrols a BLAKE2B hash of `limine.conf` into the Limine binary, and **under
Secure Boot a mismatch is a panic**. Sorting before it means the file is final
before it is hashed. Nothing enrols by default (`ENABLE_ENROLL_LIMINE_CONFIG`
is unset), so this costs nothing today — it is what stops the tool becoming a
boot failure the day someone turns Secure Boot on.

## Why the splash does not flash away

The last black gap in the boot is between the splash and the login screen, and
it is an ordering problem, not a timing one:

```
sddm.service    After=... plymouth-quit.service ...
plymouth-quit   ExecStart=-/usr/bin/plymouth quit
```

Plymouth is told to quit *first*. A plain `quit` hides the splash and hands the
console back, so the screen goes black; only then does SDDM start, and its
greeter takes a second or two to come up and paint. Hence a splash that appears
for a few seconds and disappears well before you can log in.

The drop-in installed at
`/etc/systemd/system/plymouth-quit.service.d/omarchy-boot-theme.conf` replaces
that one command with `plymouth quit --retain-splash`, which leaves plymouthd's
last frame in the framebuffer on the way out instead of clearing it. Nothing
else moves: the same service runs at the same point, Plymouth still exits and
still releases the DRM device. The image simply stays up until SDDM paints over
it.

The other way round — ordering `plymouth-quit` *after* `display-manager.service`
so Plymouth keeps drawing until SDDM is up — is not used here. `sddm.service` is
already ordered after `plymouth-quit.service`, so that is an ordering cycle, and
systemd resolves cycles by dropping an edge of its own choosing. A boot that
sometimes races is worse than a boot with a seam in it.

The other end of the boot needed nothing. Omarchy overrides `HOOKS` in
`/etc/mkinitcpio.conf.d/omarchy_hooks.conf` — not in `mkinitcpio.conf`, which
still holds a stock list — and the effective list puts `plymouth` second, ahead
of `autodetect`, with `kms` for early modesetting. The splash is already coming
up as early as it can. If SDDM ever fails to start, the retained splash is what
stays on screen; `Ctrl+Alt+F2` switches VT, which does a modeset and brings the
console back.

## Why the root halves are in /usr/local/bin

`omarchy-limine-theme` and `omarchy-splash-wallpaper` install to
`/usr/local/bin`, root-owned, while `omarchy-boot-theme` installs to
`~/.local/bin`. A boot hook and a systemd unit both run those two as root, and a
root-run unit that executes a file its owner can rewrite hands root to anything
running as that user — at the next kernel update or the next wallpaper change.
Earlier versions installed the Limine half to `~/.local/bin` and the boot hook
pointed at it there; `install.sh` removes that copy if it finds it.

## Safety

`limine.conf` decides whether the machine boots, so `omarchy-limine-theme`:

- writes only between its own markers and the lines it comments, and replaces
  that block rather than appending to it,
- puts the block **above the first `/` entry**, and comments nothing below it —
  a global option after an entry belongs to that entry instead, which would
  silently not work in one direction and silently break an entry in the other,
- copies the original to `limine.conf.omarchy-limine-theme.bak` on first run,
- refuses a `limine.conf` with no menu entries, refuses to install a rewrite
  that changed the entry count, and refuses one that still has a duplicate
  definition of any colour it manages.

`omarchy-splash-wallpaper` rewrites two files it does not own, both of which are
regenerated from upstream defaults behind its back, so it refuses rather than
guesses when either has changed shape: no `logo.sprite` in `omarchy.script`, or
no logo block or root colour line in the SDDM template, and it writes nothing.
A broken `Main.qml` is a login screen you cannot type into.

If the boot menu is ever wrong, any Limine entry still boots — the colours are
cosmetic — and the original is at `/boot/limine.conf.omarchy-limine-theme.bak`.

## Tests

```
./test/all.sh
```

82 checks against fixtures, never against `/boot` or `/usr/share`. Beyond the
happy path they cover every bug this has shipped with, so none of them come
back:

- **The competing globals.** The Limine fixture is now Omarchy's real
  `limine.conf` — its Tokyo Night block included. The first version of the
  suite used a clean file with no colours in it, passed everything, and shipped
  a tool that did nothing on the actual machine. There are assertions that
  Omarchy's values get superseded, that the `color`/`colour` alias is treated as
  one option, and that exactly one live definition of each survives.
- **The white login screen.** An assertion that the White theme comes out
  `color: "#ffffff"`, which is the sed-ordering bug stated as a test, plus
  assertions that no image is layered over it and that exactly one `Image`
  block — the logo — was removed, so the lock, entry and bullet glyphs are
  still there.
- **Placement.** A global option after the first `/` entry belongs to that
  entry, not to the file. There is an assertion that the block sits above the
  first entry, and one that an option inside an entry is left alone.
- **Root's environment.** `omarchy-theme-dir` composes its answer from `$HOME`
  and `$OMARCHY_PATH`, so the boot hook — which runs as root — resolved every
  theme to `/themes/<slug>` and failed on a path that never existed. The suite
  runs the tool with `HOME=/root OMARCHY_PATH=` and checks both that it works
  and that an unknown slug is still refused there.
- **Re-appliability.** Both halves are applied twice, and after their block has
  been wiped by an upstream regeneration, and have to come out with exactly one
  block either way.
- **Serialisation.** Two runs inside `mkinitcpio` at once is a corrupt
  initramfs. One run holds the lock while a second starts; the second has to
  wait for it and leave a single block behind.
- **Awkward wallpapers.** An animated GIF has to yield exactly one
  `background.png`, and a transparent one has to flatten to the theme's
  background colour — asserted as an exact pixel value, since the wrong call
  here fails by producing a plausible-looking grey.
- **Valid QML.** When `qmllint` is present the generated `Main.qml` is linted,
  and has to report zero errors and no more warnings than the upstream template
  it came from.
- **Refusals**, since the failure modes are a machine that does not boot and a
  login screen that cannot be typed into: a `limine.conf` with no entries, an
  unknown theme, a dangling wallpaper symlink, a rewrite that changed the entry
  count, and an upstream file whose shape has changed are all left untouched
  rather than half-written.

## Status

Applied to this machine and verified live. The boot menu took the theme, and
the `post.d` hook fired on both initramfs rebuilds of that run — which is the
kernel-update path proving itself rather than being argued for. `background.png`
is installed at `3840x2400` / 37KB with the marked block present;
`Main.qml` reads `color: "#ffffff"`, so the black-login-screen bug is gone here.

The wallpaper watch has been driven end to end: relinking `current/background`
to the target it already had raises the same inotify events a real wallpaper
change does, and the service fired, reported `splash already on this wallpaper
— nothing to rebuild`, and finished inside the same second. So both the trigger
and the early exit are known to work, not assumed. `ln -nsf` was separately
confirmed to raise `CREATE`/`MOVED_FROM`/`MOVED_TO` **on the watched
directory**, which is inside `PathChanged=`'s inotify mask.

The plain login screen and the `plymouth-quit` drop-in came after that run and
need another `./install.sh`, which needs a password. The generated `Main.qml`
lints clean either way.

Two things cannot be checked without booting.

**That Plymouth honours a negative sprite `z`.** No theme shipped on this
machine uses one, so it rests on Plymouth's sprites being z-sorted. If some
Plymouth ignored it, the background would tie with the progress box at `z 0`
and hide its outline — the wallpaper, the splash and the password field would
all still be there. That is the reason for choosing `-100` over reordering
upstream's sprites: the way to be wrong about it is cosmetic.

**That `--retain-splash` closes the gap on this hardware.** It is what the
option is for, and the drop-in changes nothing but that one flag, so the
failure mode is the black gap that is already there rather than a new one. What
it cannot promise is that SDDM's own compositor comes up without a modeset of
its own; if it does, the seam moves rather than disappearing.
