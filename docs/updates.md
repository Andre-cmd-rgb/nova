# Updates and going back

Nova updates as one piece, every two weeks, and every update can be undone.

## How updates work

Nova follows Arch Linux two weeks behind, tested:

1. On the 1st and the 15th of each month a release candidate is built and installed in a virtual machine.
2. Once it has been tried on real hardware, it becomes a release.
3. Your computer stays on its release's packages, and the Arch snapshot it was tested against, until you update.

A notification says when a release is out, and a badge stays in the bar until it is installed.

## Installing an update

- **Settings → Updates**, or a click on the badge, installs it with one password or fingerprint. **`nova update`** does the same in a terminal; `--dry-run` shows what would change.
- A snapshot is taken before and after, so you can [go back](#going-back).
- Afterwards the shell restarts on the new release. Packages held with `IgnorePkg` stay held.
- While it installs, the computer neither shuts down nor sleeps on a closed lid; it sleeps once the update is over.

The same update brings the apps outside Nova's own packages:

- **Chrome and VS Code** are built on your computer from their AUR recipes, as neither may be redistributed. A recipe that changed more than its version is shown to you first. One that fails does not stop the update: it says which app was left behind, with Try Again.
- **Flathub's apps** update with `flatpak update`, without a password. The badge does not light for them alone.
- **Apps from Arch** are part of the system and move with each release.
- **Device firmware** is listed in Settings → Updates, through fwupd (`nova update firmware`).
- Claude Code and Codex come through `mise`: `mise up` updates them.

## Release candidates

Settings → Updates → **Test release candidates**, or `nova update --candidates on`, gets the next release two weeks early. `off` stops at the next final release.

## Going back

Every change to the system's packages takes a snapshot first. The boot menu keeps the last three.

1. **Restart into the boot menu**: `nova recovery`, Settings → Updates → Restart to recovery, or the menu's System → Restart to Recovery…. A key pressed in the first second of any start opens it too.
2. **Pick Snapshots**, then the system as it was before a change.
3. **Try it.** What you do in a snapshot lives in memory, and is gone at the next restart.
4. **To keep it**, take the notification's **Restore now**, or run `limine-snapper-restore`.

Snapshots hold the system, not `/home`: going back never touches your files, and nothing backs them up either.

`nova update` never moves to an older release by itself. `nova update --version <tag> --allow-downgrade` does, while that release's packages are still kept.

## When something goes wrong

- **`nova doctor`** looks the system over and says how to fix what it finds (Settings → Updates → Check for problems). `sudo nova doctor` also checks the boot menu's entries.
- **A bug report**: Settings → Updates → Bug report → **Save**, or `nova doctor --bundle`, writes one `.tar.gz` to Downloads: what `nova doctor` finds, the journal, crashes, versions, devices and the graphics memory each program holds, with names, e-mail and network addresses and serial numbers masked. Read it before you send it.
- **A part of the desktop stops working**: the menu's Update → Restart a Service, or `nova restart shell|audio|wifi|bluetooth`.
- **The disk is too full**: an update stops before it changes anything when `/` has less than 4 GiB free. `snapper list` and `sudo snapper delete <number>` remove old snapshots; `sudo pacman -Sc` old downloads.
- **The boot entries are incomplete after an update**: `sudo limine-update` writes them again.
- **The power went out mid-update**: the next `nova update` clears pacman's stale lock and goes on.
- **A service of Nova's fails**: a notification names it once; Check for problems says more.
- **The install stopped**: see [installing Nova](install.md#when-the-install-stops).
- **A fault of this one computer** (a bad memory cell, a device that needs a quirk) is fixed with a [patch](patches.md), which a reinstall keeps.

Apps are installed and removed in the [App Center](apps.md).
