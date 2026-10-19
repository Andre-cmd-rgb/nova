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

- **The splash goes black for a few seconds before the login screen arrives.**
  SDDM runs its greeter inside a whole Hyprland, and that compositor paints its
  own `#111111` background while the greeter starts.

This puts the boot menu on your theme's colours, puts your current wallpaper
behind both the splash and the login screen, paints out the gap between them,
and keeps all of it there.

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
| `/usr/share/sddm/themes/omarchy/` | `background.png`, and a regenerated `Main.qml` |
| `/usr/share/sddm/hyprland.lua` | one `background_color` line in the greeter compositor's `misc` block |
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

**The password box moves below the branding.** The box is centred and so is a
wallpaper's branding, so at first they simply overlapped. The offset is
measured rather than guessed: `-trim` returns the bounding box of everything
that is not the colour in the rendered image's own corner — the wordmark, on a
wordmark-on-a-field wallpaper — and the box goes below where that ends.

The gap is a quarter of the branding's *own height*, not a slice of the screen.
A wordmark and a small mark want the box a different distance away, and the one
thing they have in common is their own size; a screen-relative gap put the box
in the lower third of a 2400px panel. On this machine the wordmark is 418px tall
and ends at 1409px, so the box sits 84px under it, at 63.1% of the screen. It is
clamped so it can never rise above the middle or fall off the bottom.

A photograph has no such margin and trims to the whole frame. That is the
signal that there is nothing to sit under, so anything covering more than 85%
of the height leaves the box centred where upstream put it.

The prompt is also scaled to 0.85. That is one `scale` on the `Row` rather than
four separate sizes, so the lock, the box, the bullets and the text shrink
together and stay aligned — setting each of them would drift the moment upstream
changed one of them.

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

The initramfs is the only slow part, and it only carries what is under
`/usr/share/plymouth/themes/omarchy/`. So the Plymouth files are compared
against what is installed before anything is written, and a run that changed
only the login screen or the greeter config skips the rebuild entirely — which
is the common case when a package upgrade puts one of those files back. The
comparison is gated on the stamp existing, because the stamp is written only
after a rebuild finishes; without one, the last run did not get that far and the
initramfs cannot be trusted whatever the files look like now. `--force` is
exempt, since the reason to reach for it is usually an initramfs you no longer
trust.

A wallpaper that renders to more than 4MB gets rendered smaller instead, in 30%
steps. It goes into the initramfs, and a soft splash beats a boot image that
doubled in size. On this machine the wallpaper renders to 37KB, so the cost is
nothing; a photograph is what the cap is there for.

## Ten things the verification passes caught

None of these showed up in normal use, and all ten would have.

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

**The stamp described the inputs but not the tool.** It recorded the theme, the
wallpaper's hash and the screen geometry — everything the output depends on
except *how the output is generated*. So moving the password box changed nothing
on a machine that had already run the previous version: the inputs matched, the
stamp read current, and the run exited early reporting "already on this
wallpaper". Every future change to the transform would have done the same.

The stamp now carries a hash of the tool itself. It over-triggers on purpose — a
comment-only edit invalidates it — because the expensive half is gated
separately on the Plymouth files actually differing, so redoing the cheap work
when nothing needed redoing costs about a second. Being wrong in that direction
is free; being wrong in the other direction is silent.

**A fixture was reading the machine's own state.** `setup()` copied the greeter
config straight from `/usr/share/sddm/hyprland.lua` — which, once this tool is
installed, already carries the line the tool writes. So the test for "a package
upgrade put upstream's file back" was handing the tool a file that was already
themed, and asserting it did nothing. The fixture now strips the marker on the
way in. Same root cause as the entry below it: the suite was describing the
developer's machine rather than a clean one.

**The config verifier could not run as root, and that read as "bad config".**
`Hyprland --verify-config` parses a config without running a compositor, which
is worth having. But it dies on `XDG_RUNTIME_DIR is not set!` *before* reading
anything, and `sudo` does not pass that variable through — so under sudo it
never reached an opinion, and the code treated silence as a verdict. The greeter
was never themed on the machine this was written for, and it said so on every
run.

Two fixes, and the second is the real one. It now runs with `XDG_RUNTIME_DIR`
pointed at its own temp directory (and `--i-am-really-stupid`, which skips only
the do-not-run-as-root check). And it distinguishes three answers rather than
two: `config ok` passes, reaching the parser without saying that refuses, and
anything else — not installed, will not start — is *no verdict*, which leaves
the structural checks to decide. A validator that cannot run must not get a
vote. The opposite default applies to `Main.qml`, where refusing costs a dark
gap and installing costs a login screen.

The test suite could not see any of this, because it ran the tool with a
developer's environment. It now runs it under `env -i` with root's, which is the
only environment the tool is ever actually used in.

**`grep` read a marker as an option.** The greeter marker is
`-- omarchy-boot-theme`, and `grep -qF "$LUA_MARK"` exits **2** with
`unrecognized option`, not 1. The up-to-date check treated that as "not
installed", so every run redid all its work and rebuilt the initramfs. `-e`
fixes it, and all three markers now use it so the next one cannot reintroduce
it. Found by a test that asserted a second run was a no-op.

**`warn` was never defined.** Four fallback paths in the greeter section called
it, and every one of them would have printed `omarchy-splash-wallpaper: line
481: warn: command not found` instead of the message explaining what was
skipped and why — exactly when the user most needed the message. Found by a test
that asserted on the text of a warning.

**The prompt scale could land on the wrong `Row`.** The rule matched
`Row {` at any indentation, so with upstream's outer `Row` gone it would
silently scale the *bullets* row instead of refusing. It now requires the
`Row` to be a direct child of the `Column`, measured from the `Column`'s own
indentation. Found by a test that expected a refusal and got a clean exit.

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

## Why the splash went black before the login screen

The first attempt at this was wrong, and the way it was wrong is worth keeping.

The ordering does look like the culprit. `sddm.service` is `After=
plymouth-quit.service`, and `plymouth quit` hides the splash and hands the
console back, so Plymouth lets go of the screen before SDDM has drawn anything.
The obvious fix is `plymouth quit --retain-splash`, which leaves the last frame
in the framebuffer instead of clearing it. That is installed, and it does what
it says.

It made no difference, because the framebuffer is not what comes next. SDDM
here is a **Wayland** greeter:

```ini
# /etc/sddm.conf.d/10-wayland.conf
[General]
DisplayServer=wayland
[Wayland]
CompositorCommand=start-hyprland -- --config /usr/share/sddm/hyprland.lua
```

SDDM starts a whole Hyprland to host the greeter. That compositor does its own
modeset, and for the seconds between coming up and the QML greeter drawing, it
paints its own background — `misc:background_color`, which defaults to
`#111111`. Nothing Plymouth leaves behind survives a new compositor taking the
display. From the journal on this machine:

```
 8.004  plymouth-quit starts
 8.164  plymouth-quit exits          <- splash released here
 8.213  sddm socket server started
10.247  greeter session started
12.511  greeter connected            <- first pixels ~4.3s later
```

So the compositor gets the theme background as well, and the gap stops being a
gap. On a white theme the whole sequence is white: Limine menu, splash,
greeter compositor, login screen. `--retain-splash` stays because it covers the
sliver before Hyprland takes over, and costs nothing.

`Hyprland --verify-config` parses a config without running it, so the generated
file is checked in the suite rather than discovered at the next boot.

**What this fixed, and what it did not.** Measured by running the greeter's own
`CompositorCommand` nested and screenshotting it: an empty greeter compositor
renders `srgb(255,255,255)`, and with the greeter loading on top of it the
screen goes 93.97% grey then 97.1% — never black at any point. `hyprctl
getoption misc:background_color` on that instance returns `4294967295` with
`set: true`, so the config is genuinely applied and not merely accepted.

That accounts for the second half of the gap. The first half is not paintable
from here. From the journal:

```
 7.659  plymouth-quit starts
 7.861  plymouth-quit finished        <- display released
 7.864  sddm started, "Using VT 1"
 9.964  greeter session started       <- compositor was up by here
12.191  greeter connected             <- login screen visible
```

`7.86 -> ~9.9` is the DRM modeset and Hyprland's own initialisation, before any
process can put a pixel on the screen. `9.9 -> 12.2` used to be black too, and
is now white. So roughly two seconds of black remain, and they are the
compositor starting, not anything this configures.

The obvious next step — keeping plymouthd alive so it holds the display across
that modeset — is deliberately not taken. plymouthd holding DRM master when
Hyprland tries to take it risks a compositor that fails to start, which is a
machine with no login screen at all. Two seconds of black is a much better
failure than that.

`/usr/share/sddm/hyprland.lua` belongs to `omarchy-settings`, so an upgrade of
that package will put the original back. That is why `installed()` checks the
file for its marker: the next wallpaper or theme change notices and puts the
line back, instead of the gap quietly returning.

The other route — ordering `plymouth-quit` *after* `display-manager.service` —
is still not used, and would not have helped either. `sddm.service` is already
ordered after `plymouth-quit.service`, so it is an ordering cycle, and systemd
resolves cycles by dropping an edge of its own choosing.

The front of the boot needed nothing. Omarchy overrides `HOOKS` in
`/etc/mkinitcpio.conf.d/omarchy_hooks.conf` — not in `mkinitcpio.conf`, which
still holds a stock list — and the effective list puts `plymouth` second, ahead
of `autodetect`, with `kms` for early modesetting. The splash already comes up
as early as it can.

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

`omarchy-splash-wallpaper` rewrites three files it does not own, all of which
are regenerated from upstream behind its back, so it refuses rather than guesses
when one has changed shape: no `logo.sprite` in `omarchy.script`, or no logo
block, root colour line or prompt `Row` in the SDDM template, and it writes
nothing. A broken `Main.qml` is a login screen you cannot type into.

Both generated files are then checked before they are installed, not after.
`Main.qml` has to pass `qmllint` with zero errors, and the greeter config has to
come back `config ok` from `Hyprland --verify-config`. Refusing leaves whatever
is installed now in place, which is a working login screen. The greeter config
is the softer of the two — it costs a dark gap rather than a login screen, and
it is upstream's file — so an unrecognised shape there warns and skips instead
of failing the run.

If the boot menu is ever wrong, any Limine entry still boots — the colours are
cosmetic — and the original is at `/boot/limine.conf.omarchy-limine-theme.bak`.

## Tests

```
./test/all.sh
```

107 checks against fixtures, never against `/boot` or `/usr/share`. Beyond the
happy path they cover every bug this has shipped with, so none of them come
back:

- **The competing globals.** The Limine fixture is now Omarchy's real
  `limine.conf` — its Tokyo Night block included. The first version of the
  suite used a clean file with no colours in it, passed everything, and shipped
  a tool that did nothing on the actual machine. There are assertions that
  Omarchy's values get superseded, that the `color`/`colour` alias is treated as
  one option, and that exactly one live definition of each survives.
- **The white login screen.** An assertion that the White theme comes out
  `color: "#ffffff"`, which is the sed-ordering bug stated as a test.
- **The password box clearing the branding.** The wallpaper fixture has a band
  of content across its middle third, so the measurement has something to find,
  and the generated offset has to land below it. `centerIn` has to be gone from
  the Column too — QML refuses it alongside an explicit `verticalCenter` — while
  the one on the entry field stays.
- **Both generated configs parsing.** `qmllint` on `Main.qml`, and
  `Hyprland --verify-config` on the greeter config. Either one failing to parse
  is a login screen that never appears, and both tools check without booting.
- **That the verifier itself ran.** A greeter config Hyprland genuinely rejects
  has to be left on disk untouched. That assertion is the only thing separating
  a working verifier from one that silently returns no verdict and installs
  whatever it was given — which is exactly what it did under sudo. Reintroducing
  that bug fails this check and no other.
- **That a changed tool reapplies.** The suite runs a copy of the tool that
  differs only by a comment and requires it to redo its work — and to *not*
  rebuild the initramfs for it, since the output is identical. Reverting the
  stamp fix fails both halves and nothing else.
- **Root's environment, not a developer's.** Every run in the suite goes through
  `env -i` with root's environment, because that is the only one the tool is
  ever used in, and the difference was worth a whole class of bug.
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

Applied to this machine and verified live across a real reboot. The boot menu
took the theme, the splash showed the wallpaper, and the `post.d` hook fired on
every initramfs rebuild — the kernel-update path proving itself rather than
being argued for.

The reboot also found the thing the reasoning had missed: the splash still went
black for a few seconds before the login screen. That is the greeter compositor,
not Plymouth, and it is fixed above. The greeter fix has not been through a
reboot yet.

The first attempt at that fix refused to apply itself, live, on this machine —
its own verifier could not run under sudo and it read that as a bad config. That
is the eighth entry above, and the reason the suite now runs everything under
root's environment.

The wallpaper watch has been driven end to end: relinking `current/background`
to the target it already had raises the same inotify events a real wallpaper
change does, and the service fired, reported `splash already on this wallpaper
— nothing to rebuild`, and finished inside the same second. `ln -nsf` was
separately confirmed to raise `CREATE`/`MOVED_FROM`/`MOVED_TO` **on the watched
directory**, which is inside `PathChanged=`'s inotify mask.

Checked without booting: the generated `Main.qml` lints clean under `qmllint`,
the generated greeter config returns `config ok` under
`Hyprland --verify-config`, the drop-in passes `systemd-analyze verify`, and the
offset measurement puts the password box at 71.7% of screen height against a
wordmark ending at 58.7%. All four run in the suite rather than by hand.

Two things still cannot be checked without booting.

**That the greeter background actually closes the gap.** `misc:background_color`
is what Hyprland paints where nothing else is drawn, and with
`force_default_wallpaper = 0` and `disable_hyprland_logo = true` nothing else
is. The config parses and the value is the theme's. What is not proven is that
no other black frame hides between the modeset and the greeter's first paint.

**That Plymouth honours a negative sprite `z`.** No theme shipped on this machine uses one, so it rests on
Plymouth's sprites being z-sorted. If some Plymouth ignored it, the background
would tie with the progress box at `z 0` and hide its outline — the wallpaper,
the splash and the password field would all still be there. That is the reason
for choosing `-100` over reordering upstream's sprites: the way to be wrong
about it is cosmetic.
