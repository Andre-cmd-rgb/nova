# Nova

<img src="docs/images/desktop.jpg" alt="The Nova desktop in the adaptive theme: a terminal and Settings, open at Appearance with its twelve themes, over a photo of an abbey on a hill at dusk, with a see-through bar along the top" width="100%">

**A light Arch Linux desktop, with what a PC needs to run properly.** Hyprland, a shell of its own, one `nova` command and a power manager, set up as one piece and installed together from a USB stick. What it does not carry, the App Center installs when you want it.

[The site](https://andre-cmd-rgb.github.io/nova/) · [Install](docs/install.md) · [Using Nova](docs/using.md) · [Releases](https://github.com/Andre-cmd-rgb/nova/releases)

## What it is like

- **It starts quietly.** The firmware's logo, then the lock screen, with no console text in between.
- **It looks like one thing.** One theme reaches the bar, the terminal, GTK and Qt apps, VS Code and Chrome at once. The adaptive theme takes its colors from your photo, and changes when the photo does.
- **One key for most things.** Super+Space opens the menu: apps, screenshots, toggles, themes, Settings and updates. A sum or a conversion typed into it is answered in the first row.
- **A Calculator of its own**, basic or scientific, with the history of your sums, in the theme's colors.
- **Space in Files** shows a file in a Quick Look window: a photo, the first page of a PDF, a frame of a video, the start of a text.
- **A calendar** of events and tasks, on your computer, kept in step both ways with iCloud or any CalDAV calendar.
- **Your iPhone, with nothing installed on it.** It sends photos and files to the computer with AirDrop, and opening its share sheet is enough to switch AirDrop on. Its notifications can show on the computer too.
- **Dictation.** Hold Super+D and speak: the words appear where you type. It runs on your computer, so nothing you say leaves it; the speech model, 669 MB, is downloaded once, at the first use.
- **Updates you can undo.** A release every two weeks, tested before you get it, with a snapshot before each update to go back to.
- **An installer stick** that installs without internet, and can carry your files over, or hold a whole Nova to start any PC from.

<p>
<img src="docs/images/menu.jpg" alt="The Nova menu open in the middle of the screen: a search field, then Apps, Capture, Toggle, Style, Settings, Update and System" width="49%">
<img src="docs/images/calendar.jpg" alt="The calendar at a week in November, with events on five of its days, and the tasks beside it: one overdue and two for no day in particular" width="49%">
</p>

## What it runs on

- Any 64-bit PC (x86-64) that starts with UEFI and has a disk of 64 GiB or more for Nova to take. Secure Boot must be off.
- Tuned in depth for the Lenovo ThinkPad P1 Gen 4i, where every release is tried before it is out.
- [Hardware support](docs/hardware.md) says what other laptops and desktops get, and how a fault of one computer is fixed.

## Install

1. **Download** from the newest [release](https://github.com/Andre-cmd-rgb/nova/releases): `nova-usb` on an Arch-based system, or the ISO its notes link on any other. The ISO, about 3 GB, carries every package, so the stick installs without internet.
2. **Make the stick**, of 4 GB or more. With `nova-usb`, run `sudo pacman -S gum`, then `bash nova-usb`: it fetches the ISO, checks it against Nova's signing key and writes the stick. Otherwise, write the ISO as it is with `dd` or any USB writer.
3. **Turn Secure Boot off** in the computer's firmware settings; the installer stops and says how when it is still on. If Windows stays on the computer and uses BitLocker or Device Encryption, it asks for its recovery key at its next start: have the key at hand first.
4. **Start the computer from the stick** (F12 at power-on on most computers, F9, F11 or Esc on some) and answer the questions. Nothing touches the disk until you type `erase`.
5. **Take the stick out and restart.** The computer starts into the lock screen.

The [install guide](docs/install.md) has the rest: each question, encryption, installing without internet, carrying files over, and a portable Nova on a USB drive.

## Keys worth knowing

| Key | Does |
|---|---|
| Super+Space | the menu |
| Super+Alt+Space | the apps |
| Super+Return | a terminal |
| Super+Shift+Return | the browser |
| Super+Shift+F | Files |
| Super+W | close the window (windows have no title-bar buttons) |
| Super+1 to Super+0 | workspaces 1 to 10 |
| Super+Ctrl+L | lock |
| Super+D | dictation: hold and speak, or tap for hands-free |
| Print | a screenshot |
| Super+K | every key, searchable |

[Using Nova](docs/using.md) has every key, the menu, the bar, Settings page by page, and the rest of the desktop.

## Updates and going back

- A notification says when a release is out, and a badge stays in the bar until it is installed.
- Settings → Updates, or `nova update` in a terminal, installs it with one password or fingerprint.
- Every update takes a snapshot first. When something is wrong after one, `nova recovery` restarts into the boot menu, whose **Snapshots** start the system as it was.
- Snapshots hold the system, not your files in `/home`: going back never touches them, and nothing backs them up either.

[Updates](docs/updates.md) has how releases are made, release candidates, and going back step by step.

## When something goes wrong

- `nova doctor` looks the system over and says how to fix what it finds. `nova doctor --bundle`, or Settings → Updates → Bug report → **Save**, writes one file to attach to a bug report, with your account's name, the computer's, addresses and serial numbers masked.
- `nova recovery` restarts into the boot menu: the last snapshots, the fallback image and the LTS kernel.
- An install that stops says at which step, and keeps its log in `/var/log/nova-install.log`.

[When something goes wrong](docs/updates.md#when-something-goes-wrong) has more. A fault of your one computer, such as a bad memory cell or a device that needs a quirk, is fixed with a [patch](docs/patches.md).

## Working on Nova

```sh
make lint                              # shellcheck, luac, qmllint, actionlint, the name check
make test                              # the unit tests (side by side with GNU parallel installed)
cargo test                             # the Rust parts
make DESTDIR=/tmp/nova-root install    # the nova package's files, into a scratch root
```

Packages and ISOs are built only by CI. Start with [the architecture](docs/ARCHITECTURE.md), the contract every component follows; [the documentation's index](docs/README.md) lists the rest.

The pictures are of the shell itself, taken by `tools/screenshots` off-screen on a Hyprland of their own, with Nova's look and window rules, so the windows are drawn as Nova draws them; they float, to leave the background in view, where Nova tiles them. The site (`site/`) is published from main by `.github/workflows/pages.yml`, with the same pictures.

## License

MIT, see [LICENSE](LICENSE). [NOTICE](NOTICE) has the licenses of the code Nova builds on.
