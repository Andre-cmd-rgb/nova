# The App Center

One window to find apps, install them, open them and remove them: the menu's **App Center**, the launcher's, or `nova apps store`. Everything it does, `nova apps` does in a terminal.

It is not called the App Store: that is Apple's name.

## Using it

- **Discover**, the front page, starts with **Popular**, about twelve of the best-known apps of every kind (a browser, VS Code, Steam, Spotify), then has the best of each kind, chosen by hand (`/usr/share/nova/apps/featured`), and **See All** for the rest of that kind. The sidebar has the kinds: Create, Work, Play, Develop, Internet, Music & Video, Learn and Utilities.
- **Search** is at the top of the sidebar; Ctrl+F goes there, and Return opens the first app found. It looks at the names, the keywords, the summaries and the IDs, and puts an app of the front page that matches before one that only has the word for a name.
- **An app's page** has its icon, name and summary, its pictures, what it says of itself, its version, size, developer and license, and its website. **Get** installs it; once it is in, **Open** starts it and **Remove…** asks once more, then removes it. A Flathub app's data goes with it; for any other app the page says that your files and settings for it stay.
- **From**, on the page of an app that comes from more than one place, picks the one to install from. Its facts say where it comes from, or came from.
- **Installed** lists what is installed, by name, with where each came from. An app that is part of Nova, or that came with another app, has no Remove.
- An install goes on with the window closed. The page, the tile and the Installed row show how far it is; one that fails says why, in a sentence ("could not download it; check the connection and try again").
- Escape, Alt+Left or a mouse's back button go back from an app's page; Ctrl+Tab goes through the sidebar.
- A web page's `appstream://` link (Flathub's **Install** button) opens the app's page.

| Command | Does |
|---|---|
| `nova apps search <words>` | what the search finds, with where each comes from |
| `nova apps info <app>` | an app's facts, and where it is installed from |
| `nova apps install <app> [--from nova\|arch\|flathub]` | installs it, from the first place it comes from or the one named |
| `nova apps remove <app>` | removes it, from wherever it is; a Flathub app's data (`~/.var/app/<id>`) goes with it |
| `nova apps list` | the installed apps |
| `nova apps store [<app> \| --search <words>]` | opens the window, on an app's page or a search |
| `nova apps update` | brings Chrome, VS Code and Flathub's apps up to date |

An `<app>` is its ID (`org.gimp.GIMP`), its package (`gimp`) or its name (`chrome`).

## Where the apps come from

| Place | What | Installed |
|---|---|---|
| Nova | Chrome and VS Code, built on this computer from their makers' releases ([updates.md](updates.md#chrome-and-vs-code)) | as an update installs them |
| Arch Linux | the apps in the release's repositories, from Arch's own catalog (`archlinux-appstream-data`) | through pacman, with one password, and a snapshot before and after |
| Flathub | the apps on Flathub | into your own Flatpak installation (`~/.local/share/flatpak`): no password |

An app that is in more than one place is **one app**, matched by its ID, the IDs it was known by before, or its name and package. Its install takes the first place in that order, and **From** offers the others.

Why Arch before Flathub, for an app in both:

- **It is what Nova tested.** An Arch package comes from the snapshot the release was tested against, and moves with Nova's updates. A Flathub app moves when its maker publishes.
- **Size.** GIMP from Arch is a 43 MB download on a Nova install (224 MB on the disk); from Flathub, 103 MB, and 433 MB more for the runtime it needs (1.1 GB on the disk), which other apps share once one has brought it.
- **Fewer surprises.** An Arch app uses the system's theme, fonts, input methods and file dialogs as everything else does; a Flathub app sees only what its sandbox lets it, which shows as a file it cannot open, or a portal's dialog.

Flathub has the case for it too: no password, often a newer version, the sandbox, and an app that comes from its own developer (the page says **Flathub, verified** for those Flathub has checked). Of the 4,061 apps in the catalog on the day this was built, 663 come from both, 717 from Arch alone and 2,679 from Flathub alone.

Chrome and VS Code come from Nova alone. Flathub has both, packaged by others (VS Code's page there says so); Nova builds them from the makers' own releases.

## Updates

Nova has one updater. The App Center installs and removes; it updates nothing.

- **Settings → Updates** and **`nova update`** bring the system, Chrome and VS Code, and Flathub's apps up to date, in that order. `nova apps update` does the apps alone.
- An app from Arch is part of the system: it moves with the release, as every package does.
- Flathub's apps and their runtimes are updated in your installation and the system's, with `flatpak update`, which asks for no password. When they cannot be, the update is finished with problems and says so, as for Chrome; Nova itself is updated all the same.
- The badge in the bar does not light for Flathub's updates alone: they come with the next update of Nova, or with `nova apps update`.

## Privileges

- Flathub: your own installation, no password; nothing of it is in the system's snapshots.
- Arch: one password or fingerprint (`org.nova.apps`), through `pkexec /usr/lib/nova/nova-apps-apply`, which installs or removes one package and nothing else: an app Arch's catalog lists, never Nova itself or a package Nova needs, never a library.
- Chrome and VS Code: built as you, then installed by the root half of `nova update`, as an update installs them.

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

## How it is built

| Part | Does |
|---|---|
| `nova-apps-catalog` (Rust, `src/apps/`) | reads Flathub's catalog (from whichever installation fetched it last), Arch's (`/usr/share/swcatalog`), the repositories' package lists and the front page, and writes one file the window and the commands read: `~/.cache/nova/apps/catalog.json`, made again only when one of those changed. Arch's icons are JPEG XL; the ones the catalog needs are made PNGs once, with `vipsthumbnail`. |
| `nova-apps-installed` | what is installed: Flathub's apps and runtimes, every package, Nova's own |
| `nova-apps-refresh` | fetches Flathub's catalog again once it is a day old, as the window opens; adds Flathub first, from the file Nova ships with Flathub's key |
| `nova-apps-run`, `nova-apps-job` | an install or a removal as a user service of its own (`nova-apps-<id>`), one at a time; how far it is, in `$XDG_RUNTIME_DIR/nova/apps/status.json`, its output in a log beside it |
| `nova-apps-apply` | the root half, for Arch, through pkexec |
| `nova-apps-shots`, `nova-apps-size` | an app's pictures, downloaded into `~/.cache/nova/apps/shots`, and what an Arch package would add: the shell itself reads files and never the network |
| `src/shell/plugins/store/` | the window |

Measured on the ThinkPad P1 Gen 4i: the catalog takes 3.1 s the first time (most of it the icons), 1.5 s when Flathub's catalog changed, and 1 ms when nothing did; its file is 6.9 MB, which the window reads in 66 ms. What is installed is read in 92 ms.

## Not yet

- Updates per app, and an app's release notes.
- Ratings and reviews (Flathub has none to give; ODRS is GNOME's).
- A larger picture on a click, and pictures for most apps of Arch's catalog, which points at the makers' sites.
- Removing the data of an app from Arch or Nova's own. They keep their files in your home, at places only each app knows, so removing the app leaves them, as a Mac app outside the sandbox does. A Flathub app's data is its sandbox folder, `~/.var/app/<id>`, and goes with it.
- Apps from the AUR, other than Chrome and VS Code.
