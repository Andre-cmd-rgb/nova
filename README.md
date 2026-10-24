# Nova

A small, fast Arch Linux desktop for laptops: Hyprland, a Quickshell shell, one
`nova` command, and power management that knows the machine it runs on. It boots
from the firmware logo straight to the lock screen, uses one theme everywhere,
and installs in a few minutes from a USB stick that can carry your things over.

> **Status: beta.** Tuned for the Lenovo ThinkPad P1 Gen 4i and the Lenovo
> Legion 5 (RTX 4070). Other x86-64 laptops and desktops with Intel, AMD or
> NVIDIA graphics should work, but are untested.

## Install

Nova takes the whole disk. Turn Secure Boot off in the firmware settings first.

**Make the stick**, from the newest [release](https://github.com/Andre-cmd-rgb/nova/releases):

- On any Arch-based system, download `nova-usb` and run `bash nova-usb` (it
  asks its questions with gum: `sudo pacman -S gum`). It writes the stick and
  can put every package on it, so the install needs no internet. It can also
  carry your things over, encrypted: SSH and GnuPG keys, Wi-Fi networks, Chrome
  signed in, VS Code, Claude Code and Codex, T3 Code, git repositories, folders,
  your own backgrounds and your extra packages. `bash nova-usb --dry-run` asks
  everything and writes nothing. It checks the ISO against the release's
  checksum, and the checksum against Nova's signing key.
- Anywhere else, write the ISO as it is, with `dd` or any USB writer. That
  stick installs over the network.

**Boot it** and answer a few questions: keyboard layout (a stick from
`nova-usb` offers the one of the computer it was made on), the passphrase of
what it carries, Wi-Fi when there is no cable, the disk, your name, user name
and password, the computer's name, the time zone, and a fingerprint if there is
a reader. Nothing touches the disk
until you type `erase`. Drivers for Intel, AMD and NVIDIA graphics, microcode
and firmware are chosen for the hardware. The computer restarts into the lock
screen. The stick's boot menu also has a memory test (memtest86+).

## Using it

- **Keys:** Super+Space opens the menu and Super+Alt+Space the apps,
  Super+Return a terminal, Super+Shift+Return Chrome and Super+Shift+F Files.
  Super+W closes a window (windows have no title-bar buttons), Super+Ctrl+L
  locks, Print takes a screenshot, and Super+K lists every binding.
- **Settings**, in the menu: Wi-Fi, Bluetooth, mobile data and sound (also a
  click away in the bar), battery (its history, power mode, charge limit, the
  discrete GPU), Screen Time, the theme and background, what the bar shows,
  the lock screen and fingerprint, default apps, updates and recovery.
  Settings → Menu Bar adds more to the bar, such as Display for brightness and
  the laptop screen.
- **Caffeine**, the coffee cup in the bar or Super+Ctrl+I, keeps the screen on:
  no screensaver, no lock when unused, and on a laptop closing the lid only
  turns the panel off, without sleeping, locking or dropping the network. It
  lasts until you turn it off or log out, or, on battery, until the battery
  is down to 10%.
- **The screensaver** plays the wordmark in text effects after three minutes
  unused, and the screen locks after five; both are in Settings → Lock Screen.
  `nova screensaver` shows it now, and `~/.config/nova/screensaver.txt`, when
  there is one, is played instead of the wordmark.
- **`nova help`** lists the commands. Chrome, VS Code, Nautilus, foot, btop,
  fastfetch, Claude Code and Codex come installed.

## Updates

Nova follows Arch two weeks behind, tested. Every other week CI builds a
release candidate and installs it in a virtual machine; once it has been tried
on real hardware it becomes a release. `nova update`, or the bar's update badge,
moves the system to the newest release, with a snapshot before and after. To
get candidates early: Settings → Updates → Test Release Candidates.

## When something is wrong

- If the install stops, it says at which step. The whole log is
  `/var/log/nova-install.log`, kept in memory until the installer restarts;
  `nova-install-start` tries again from the start, with no restart needed,
  and keeps the stopped try's log as `nova-install.log.1`.
- `nova doctor` looks the system over and says how to fix what it finds; `sudo
  nova doctor` also checks the boot menu's fallback entry.
- `nova recovery` restarts into the boot menu: the last snapshots, the fallback
  image and the LTS kernel. Any key during the first second of boot opens it too.

## Working on Nova

```sh
make lint                                 # shellcheck, luac, qmllint, actionlint, the name check
make test                                 # the unit tests
cargo test
make DESTDIR=/tmp/nova-root install       # the nova package's files, into a scratch root
```

Packages, ISOs and releases are built only by CI. Actions → candidate → Run
builds `main` into a pre-release with an ISO, installed and booted in QEMU
before it is published.

- [Architecture](docs/ARCHITECTURE.md): how the pieces fit, and the rules for code
- [Releasing](docs/releasing.md): versions, the signing key, the two-week cycle
- [Packaging](docs/packaging.md): the kernel, the NVIDIA modules and the AUR rebuilds
- [Hardware notes](docs/hardware/): what was measured on the P1 Gen 4i, and why

## License

MIT, see [LICENSE](LICENSE). The shell, the Hyprland defaults and the palettes
derive from [Omarchy](https://github.com/basecamp/omarchy) (MIT); see
[NOTICE](NOTICE).
