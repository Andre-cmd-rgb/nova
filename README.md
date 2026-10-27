# Nova

An Arch Linux desktop for laptops and the Raspberry Pi 5: Hyprland, a
Quickshell shell, one `nova` command, and power management that knows the
machine it runs on. It boots from the firmware logo straight to the lock
screen, uses one theme everywhere, and installs in a few minutes from a USB
stick that can carry your files over.

**Status: beta.** Tuned for the Lenovo ThinkPad P1 Gen 4i, and runs on the
Raspberry Pi 5. The Lenovo Legion 5 (RTX 4070) has a first profile, not yet
tuned. Other x86-64 laptops and desktops with Intel, AMD or NVIDIA graphics
should work, but are untested.

## Install on a PC

Nova takes the whole disk, of 64 GiB or more, and starts with UEFI. Turn
Secure Boot off in the firmware settings first, and download the newest
[release](https://github.com/Andre-cmd-rgb/nova/releases).

**1. Make the stick.** On an Arch-based system, run the release's `nova-usb`:

```sh
sudo pacman -S gum     # nova-usb asks its questions with gum
bash nova-usb          # --dry-run asks everything and writes nothing
```

It checks the ISO against the release's checksum, and the checksum against
Nova's signing key, then writes the stick. It can also put every package on
it, so the install needs no internet, and carry your SSH keys and the files
and folders you pick from your home, encrypted. Chrome, VS Code, Claude Code
and Codex are the exception: an offline install says so, and
`nova apps install; mise install` adds them once online.

On any other system, write the ISO as it is with `dd` or any USB writer. That
stick installs over the network.

**2. Boot it** and answer the questions: the keyboard layout (a stick from
`nova-usb` offers the one of the computer it was made on), the passphrase of
what it carries, Wi-Fi when there is no cable, the disk, your name, user name
and password, the computer's name and time zone, and a fingerprint if there is
a reader. Nothing touches the disk until you type `erase`.

The installer picks the drivers for Intel, AMD and NVIDIA graphics, the
microcode and the firmware, and the computer restarts into the lock screen.
The stick's boot menu also has a memory test (memtest86+).

## Install on a Raspberry Pi 5

Write the release's `nova-<version>-raspberry-pi-5.img.xz` to a card, a USB
stick or an NVMe drive, with Raspberry Pi Imager (*Use custom*) or:

```sh
xzcat nova-<version>-raspberry-pi-5.img.xz | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
```

At its first start the Pi grows the system to fill the drive, and asks what
the PC installer asks: the keyboard layout, the computer's name and time zone
(which also sets the country's Wi-Fi channels), Wi-Fi when there is no cable,
and your name, user name and password. Then it installs the apps and starts
into the lock screen. What differs from a PC is in
[the Pi's notes](docs/hardware/raspberry-pi-5.md).

## Using Nova

| Key | Opens or does |
|---|---|
| Super+Space | the menu |
| Super+Alt+Space | the apps |
| Super+Return | a terminal |
| Super+Shift+Return | the browser (Chrome) |
| Super+Shift+F | Files |
| Super+W | close the window (windows have no title-bar buttons) |
| Super+Ctrl+L | lock |
| Super+Ctrl+I | Caffeine |
| Super+D | dictation: hold and speak, or tap for hands-free |
| Print | a screenshot |
| Super+K | every binding |

- **Settings**, in the menu: Wi-Fi, Bluetooth, mobile data and sound (also a
  click away in the bar), the battery (its history, the power mode, the charge
  limit, the discrete GPU), Screen Time, the theme and background, what the bar
  shows, the lock screen and fingerprint, default apps, updates and recovery.
  Settings → Menu Bar adds more to the bar, such as Display for the brightness
  and the laptop screen.
- **Dictation:** hold Super+D and speak, and the words are pasted where the
  cursor is when you let go; a tap listens until the next press, and Esc
  cancels. It runs on the computer (NVIDIA's Parakeet, in 25 European
  languages), and nothing leaves it: the speech model, 669 MB, is downloaded
  once, at the first press, when you say yes. Not on the Raspberry Pi.
  `nova dictation` says whether it is ready.
- **Caffeine**, the coffee cup in the bar, keeps the screen on: no
  screensaver, no lock when unused, and on a laptop closing the lid only turns
  the panel off, without sleeping, locking or dropping the network. It lasts
  until you turn it off or log out, or, on battery, until the battery is down
  to 10%.
- **The screensaver** plays the wordmark in text effects after three minutes
  unused, and the screen locks after five; both are in Settings → Lock Screen.
  `nova screensaver` shows it now, and `~/.config/nova/screensaver.txt`, when
  there is one, is played instead of the wordmark.
- **Apps:** Chrome, VS Code, Nautilus, foot, btop, fastfetch, Claude Code and
  Codex come installed.
- **`nova help`** lists the commands.

## Updates

Nova follows Arch Linux two weeks behind, tested. On the 1st and the 15th of
each month CI builds a release candidate and installs it in a virtual machine;
once it has been tried on real hardware it becomes a release. `nova update`, or
the update badge in the bar, moves the system to the newest release, with a
snapshot before and after (a Raspberry Pi has no snapshots). Settings → Updates
→ Test Release Candidates gets the candidates early.

## When something goes wrong

- **The install stops:** it says at which step. The whole log is
  `/var/log/nova-install.log`, kept in memory until the installer restarts.
  `nova-install-start` tries again from the start without a restart, and keeps
  the stopped try's log as `nova-install.log.1`.
- **A Pi's first start stops:** it says at which step, and starts over at the
  first question, as it does after a power cut. Its log is
  `/var/log/nova-first-boot.log`.
- **`nova doctor`** looks the system over and says how to fix what it finds;
  on a PC, `sudo nova doctor` also checks the boot menu's fallback entry.
- **`nova recovery`**, on a PC, restarts into the boot menu: the last
  snapshots, the fallback image and the LTS kernel. Any key in the first
  second of the boot opens it too.

## Working on Nova

```sh
make lint                              # shellcheck, luac, qmllint, actionlint, the name check
make test                              # the unit tests
cargo test
make DESTDIR=/tmp/nova-root install    # the nova package's files, into a scratch root
```

Packages, ISOs and images are built only by CI. Actions → candidate → Run
builds `main` into a pre-release, whose ISO is installed and booted in QEMU
before it is published.

| Read | For |
|---|---|
| [Architecture](docs/ARCHITECTURE.md) | how the pieces fit, and the rules for code |
| [The shell](src/shell/README.md) and [its plugins](src/shell/plugins/README.md) | the bar, the panels, the lock screen |
| [Power](docs/power.md) and [its code](src/power/README.md) | `nova power`: the GPU, the CPU's limits and the fans |
| [Releasing](docs/releasing.md) | versions, the signing key, the two-week cycle |
| [Packaging](docs/packaging.md) | the kernel, the NVIDIA modules, the AUR rebuilds |
| [ThinkPad P1 Gen 4i](docs/hardware/thinkpad-p1-gen4i.md) | what was measured on it, and why |
| [Raspberry Pi 5](docs/hardware/raspberry-pi-5.md) | how Nova runs on it |

## License

MIT, see [LICENSE](LICENSE). [NOTICE](NOTICE) has the licenses of the code
Nova builds on.
