# The App Center

One window to find apps, install them, open them and remove them: **App Center** in the menu, or `nova apps store`. Everything it does, `nova apps` does in a terminal.

## Using it

- **Discover** starts with the best-known apps (a browser, VS Code, Steam, Spotify), then a hand-picked few of each kind. The sidebar has the kinds and **Installed**.
- **Search** is at the top of the sidebar (Ctrl+F); Return opens the first app found.
- **An app's page** has its pictures, description, size and licence. **Get** installs it; **Open** starts it; **Remove…** asks once more. Where an app comes from more than one place, **From** picks which.
- **Also installs** on a page lists what comes with the app so that it works: VLC's codecs, Lutris's Wine, virt-manager's QEMU. Those extras go again when the app is removed.
- An install carries on with the window closed; one that fails says why in a sentence.
- A web page's `appstream://` link (Flathub's **Install** button) opens the app's page.

| Command | Does |
|---|---|
| `nova apps search <words>` | what the search finds, and where each comes from |
| `nova apps info <app>` | an app's facts |
| `nova apps install <app> [--from arch\|flathub\|nova]` | install it |
| `nova apps remove <app>` | remove it (a Flathub app's data in `~/.var/app/<id>` too) |
| `nova apps list` | the installed apps |
| `nova apps update` | bring Chrome, VS Code and Flathub's apps up to date |

An `<app>` is its ID (`org.gimp.GIMP`), package (`gimp`) or name (`chrome`).

## Where apps come from

| Source | What | Installed |
|---|---|---|
| Arch Linux | the release's own repositories | through pacman, with one password, and a snapshot before and after |
| Flathub | the apps on Flathub | into your own Flatpak installation, no password |
| Nova | Chrome and VS Code, built on your computer from their makers' releases | as an update installs them |

An app in more than one place is one app, and installs from Arch first: that is the version the release was tested with, it uses the system's theme, fonts and file dialogs, and it is usually far smaller (GIMP: 43 MB from Arch, 103 MB plus a 433 MB runtime from Flathub). A few apps go to Flathub first because Arch's package breaks on a pinned snapshot (Discord) or lacks pieces. Flathub has its own case: no password, often a newer version, a sandbox. **From** offers the other source.

Supernova, Nova's browser, comes with Nova and updates with it; it is not in the App Center.

## Games

- **Steam** installs from Arch with the 32-bit Vulkan driver for your graphics card, and nothing for a card you don't have.
- **Windows games** (Proton, Wine) get the kernel's `ntsync`, and controllers work through `steam-devices`.
- **On a laptop with an NVIDIA card**, a game marked for the discrete GPU starts on it while plugged in ([power](power.md#the-discrete-gpu)). Flatpak games get the NVIDIA runtime that matches the installed driver, kept in step by `nova update`.
- Games are drawn opaque, so fullscreen goes straight to the display.
- `nova doctor` checks all of this under **Games & Apps**, with a fix for what it finds.

## Updates and privileges

- Nova has one updater: [Settings → Updates and `nova update`](updates.md) bring Arch's apps with the release, then Chrome and VS Code, then Flathub's. The App Center installs and removes; it updates nothing.
- Arch installs go through `pkexec /usr/lib/nova/nova-apps-apply`, which installs or removes one app from Arch's catalog and what its recipe adds, never a library or a part of Nova.
- **Never a partial upgrade.** It installs with `pacman -S --needed`, never `-Sy`, against the release's pinned snapshot; it refuses while packages are behind their lists (update first), after an update that stopped halfway, and while another update or install runs.

## Not yet

- Per-app updates and release notes; ratings and reviews.
- Removing the data an Arch app keeps in your home (Flathub apps' data goes with them).
- Apps from the AUR, other than Chrome and VS Code.

How the App Center is built is in its [maintainer notes](../src/apps/README.md).
