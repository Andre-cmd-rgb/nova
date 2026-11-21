# The App Center: maintainer notes

The App Center's catalog (Rust, `src/`) and its helpers (`bin/`), which
`nova apps` runs too; the window is the shell's (`src/shell/plugins/store/`).
What users see is in [docs/apps.md](../../docs/apps.md).

<!-- Moved from docs/apps.md (RC15 docs rewrite): the parts that are about how
     the App Center is built rather than how it is used. -->

## How it is built

| Part | Does |
|---|---|
| `nova-apps-catalog` (Rust, `src/apps/`) | reads Flathub's catalog (from whichever installation fetched it last), Arch's (`/usr/share/swcatalog`), the repositories' package lists and the front page, and writes what the window and the commands read into `~/.cache/nova/apps/`, made again only when one of those changed: `catalog.json`, every app whole, which the commands read; `list.json` (`nova-apps-catalog --list` prints its path), each app with only what lists and search use, which the window reads; and `pages/`, a file for each app with all of it, which the window reads when an app's page opens, so that it does not hold every app's description and pictures (parsing the 6.9 MB catalog took 59 MB of memory, the 1.9 MB list 20). Arch's icons are JPEG XL; the ones the catalog needs are made PNGs once, with `vipsthumbnail`. |
| `nova-apps-installed` | what is installed: Flathub's apps and runtimes, every package, Nova's own |
| `nova-apps-refresh` | fetches Flathub's catalog again once it is a day old, as the window opens; adds Flathub first, from the file Nova ships with Flathub's key |
| `nova-apps-run`, `nova-apps-job` | an install or a removal as a user service of its own (`nova-apps-<id>`), one at a time; how far it is, in `$XDG_RUNTIME_DIR/nova/apps/status.json`, its output in a log beside it |
| `nova-apps-apply` | the root half, for Arch, through pkexec |
| `nova-apps-shots`, `nova-apps-size` | an app's pictures, downloaded into `~/.cache/nova/apps/shots`, and what an Arch package would add: the shell itself reads files and never the network |
| `src/shell/plugins/store/` | the window |

Measured on the ThinkPad P1 Gen 4i: the catalog takes 3.1 s the first time (most of it the icons), 1.5 s when Flathub's catalog changed, and 1 ms when nothing did; its catalog is 6.9 MB and its list 1.9 MB. What is installed is read in 92 ms.

## Never a partial upgrade

Arch is safe to install from only when the package lists and the installed packages are from the same moment. `nova-apps-apply`:

- installs with `pacman -S --needed`, never `-Sy`: it never reads newer lists, which would leave everything installed behind them. Nova pins Arch's repositories to the release's snapshot, so the lists on a system that is up to date are the ones its packages came from.
- reads the lists only where one is missing, as on a system installed from a stick; the pins make them the release's snapshot.
- installs nothing while the packages are behind their lists (`pacman -Qu`, leaving out what `IgnorePkg` holds back), as an update that did not finish leaves them: it says to update first.
- installs nothing after an update that stopped halfway (its `.nova-prev` pins), nor while an update or another install runs (`/run/nova-update.lock`).

## Why a window of Nova's own

GNOME Software and KDE Discover were the alternatives. On Arch:

- **GNOME Software cannot install from Arch's repositories at all.** Arch builds it without PackageKit, the only way it has to reach pacman; it does Flathub and firmware only. It would also update Flathub's apps by itself, in the background: a second updater.
- **Discover reaches pacman only through PackageKit, which Arch's package calls "not recommended, use at your own risk".** PackageKit reads newer package lists by itself when it refreshes, and an install after that is the partial upgrade above. Discover also has an update notifier of its own, and on a Nova install pulls in 63 packages (160 MB) of KDE's libraries.
- Neither knows Nova's own apps, its pinned snapshot, its updater, or its look.

So the window is the shell's, as Settings is, and stands on small commands that `nova apps` runs too.

## The catalog's numbers

Of the 4,061 apps in the catalog on the day the App Center was built, 663
came from both Arch and Flathub, 717 from Arch alone and 2,679 from Flathub
alone.
