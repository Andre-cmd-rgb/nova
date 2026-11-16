# Updates and going back

This page covers how Nova updates, release candidates, going back to before an update, and what to do when something goes wrong.

## How updates work

Nova follows Arch Linux two weeks behind, tested.

1. On the 1st and the 15th of each month, a release candidate is built and installed in a virtual machine.
2. Once it has been tried on real hardware, the ThinkPad P1 Gen 4i, it becomes a release.
3. Your computer stays on its release's packages, and the Arch snapshot that release was tested against, until you update.

When a release is out, a notification says so, once, and the update badge in the bar stays until it is installed.

## Installing an update

- **Settings → Updates**, or a click on the badge, moves the system to the newest release. It shows how far it is, and asks for one password or fingerprint.
- **`nova update`** does the same in a terminal. `nova update --dry-run` shows what would change and changes nothing.
- Every update takes a snapshot before and after, so you can [go back](#going-back-to-before-an-update).
- Packages you hold back with `IgnorePkg` stay held back.
- While it installs, the computer does not shut down or restart, and **closing the lid does not stop it**: the screen locks and goes dark as usual, but the computer stays awake until the update is over, and then sleeps if the lid is still shut. Suspend from the menu still sleeps, and so does a battery about to run out; the update goes on after the wake. The hold ends with the update, however it ends.

### Chrome and VS Code

Chrome and VS Code update with Nova. Neither may be redistributed, so each is built on your computer from its AUR recipe, which downloads from its maker.

- A new version whose recipe changed nothing but the version and checksums is built without asking.
- Any other change to a recipe is shown first: Settings shows it and builds it once you have read it, and a terminal asks.
- One that cannot be built or installed does not stop the update: Nova is updated all the same, and then the update says which app was left behind. Settings → Updates says it with **Try Again**, and so does a notification; `nova update` says it last, with `nova apps update` to try again, and ends with status 4, finished with problems.

Claude Code and Codex come through `mise`: `mise up` updates them.

### Device firmware

Settings → Updates lists firmware updates from the makers of your devices, through fwupd. The menu's Update → Firmware opens the same page, and `nova update firmware` runs it in a terminal.

## Release candidates

A candidate is the next release, two weeks before everyone else gets it.

- Turn on Settings → Updates → **Test Release Candidates**, or run `nova update --candidates on`. `off` stops.
- A computer on a candidate keeps following candidates until a final release.

## Going back to before an update

Every change to the system's packages takes a snapshot first, an update included. The boot menu keeps the last three.

1. **Restart into the boot menu**: `nova recovery`, Settings → Updates → Restart to Recovery, or the menu's System → Restart to Recovery. A key pressed in the first second of any start opens it too.
2. **Pick Snapshots**, then the system as it was before a change, newest first.
3. **Try it out.** A snapshot starts as it was, but what is done in it lives in memory only, and is gone at the next restart.
4. **To keep it**, take the notification's **Restore now**, or run `limine-snapper-restore`. The snapshot becomes the system, and the computer restarts.

Snapshots hold the system, not `/home`: going back never touches your files, and nothing backs them up either.

### Going back a whole release

`nova update` never moves to an older release unasked. To go back to one:

```sh
nova update --version <tag> --allow-downgrade
```

It warns first: packages newer than that release's Arch snapshot are downgraded.

## When something goes wrong

- **`nova doctor`** looks the system over and says how to fix what it finds. Settings → Updates → Check for Problems runs it too. `sudo nova doctor` also checks the boot menu's fallback entry, which only root can read.
- **`nova recovery`** restarts into the boot menu: the last snapshots ([above](#going-back-to-before-an-update)), the fallback image, for a start after a hardware change, and the LTS kernel, for when a new kernel misbehaves.
- **The boot entries don't check out after an update**: the update says what is missing. `sudo limine-update` writes them again, and `nova update --check-boot` looks again before you restart.
- **The disk is too full**: an update looks first, and stops before it changes anything, when `/` has less than 4 GiB free (for its downloads, and its new packages beside the old ones its snapshot keeps), or the boot partition has no room to write its boot images once more. Old snapshots keep deleted files on `/` and boot images on the boot partition: `snapper list`, then `sudo snapper delete <number>`. `sudo pacman -Sc` deletes old downloads. `nova doctor` says how full each is.
- **The power went out in the middle of an update**: the next `nova update` takes away the lock pacman left behind (only one from before that start: one made since may be a pacman at work) and keeps what was there before the unfinished update to go back to.
- **A part of the desktop stops working**: the menu's Update → Restart starts the shell, audio, Wi-Fi or Bluetooth again (`nova restart shell`, `audio`, `wifi`, `bluetooth`).
- **The install stops**: [installing Nova](install.md#when-the-install-stops) says what to do.
- **A fault of this one computer**, such as a bad memory cell or a device that needs a quirk, is fixed with a [patch](patches.md), which a reinstall keeps.
