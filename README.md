# Nova

<img src="docs/images/desktop.jpg" alt="The Nova desktop in the adaptive theme: a terminal and Settings at Appearance over Matterhorn at dusk, with the transparent bar along the top" width="100%">

**A light Arch Linux desktop, with what a PC needs to run properly.** Hyprland, a shell of its own, one `nova` command and a power manager, set up as one piece and installed from a USB stick. What it does not carry, the App Center installs when you want it.

[The site](https://andre-cmd-rgb.github.io/nova/) · [Install](docs/install.md) · [Using Nova](docs/using.md) · [Keys](docs/keys.md) · [Releases](https://github.com/Andre-cmd-rgb/nova/releases)

## What it is like

- **One key for most things.** Super+Space opens the menu: apps, Settings, toggles, themes, updates, and the answer to a sum or a conversion typed into it.
- **One theme, everywhere.** Twelve themes reach the bar, the terminal, GTK and Qt apps, Supernova, Chrome and VS Code at once. The adaptive one takes its colors from your background.
- **Apps of its own**: a calendar that syncs with iCloud or any CalDAV server, a Calculator, Quick Look on Space in Files, and Supernova, Nova's browser.
- **Dictation on your computer.** Hold Super+D and speak; nothing you say leaves the computer, and the speech model, 669 MB, is downloaded once, at the first use.
- **Updates you can undo.** A tested release every two weeks, with a snapshot before each update to go back to.
- **An installer stick** that needs no internet, can carry your files over, or hold a whole Nova to start any PC from.
- **Your iPhone's notifications** on the computer, with nothing to install on it (a preview).

<p>
<img src="docs/images/menu.jpg" alt="The Nova menu in the middle of the screen: a search field, then Apps, Capture, Toggle, Style, Settings, App Center, Update and System" width="49%">
<img src="docs/images/calendar.jpg" alt="The calendar at a week, with events on three of its days, and the tasks beside it" width="49%">
</p>

## Install

Any 64-bit PC (x86-64) with UEFI and a disk of 64 GiB or more, with Secure Boot off.

1. **Download** `nova-usb` (on an Arch-based system) or the ISO from the newest [release](https://github.com/Andre-cmd-rgb/nova/releases).
2. **Make the stick**, 4 GB or more: `sudo pacman -S gum`, then `bash nova-usb`. Or write the ISO with any USB writer.
3. **Start the computer from the stick** (F12 at power-on on most computers) and answer the questions. Nothing touches the disk until you type `erase`.

The [install guide](docs/install.md) has the rest.

## Keys worth knowing

| Key | Does |
|---|---|
| Super+Space | the menu |
| Super+Return | a terminal |
| Super+Shift+B | the browser |
| Super+Shift+F | Files |
| Super+W | close the window |
| Super+1 to Super+0 | workspaces 1 to 10 |
| Super+D | dictation: hold and speak |
| Print | a screenshot |
| Super+K | every key, searchable |

## When something goes wrong

- `nova doctor` looks the system over and says how to fix what it finds; `nova doctor --bundle` writes a file for a bug report, with personal details masked.
- `nova recovery` restarts into the boot menu, whose **Snapshots** start the system as it was before an update.
- [Updates and going back](docs/updates.md#when-something-goes-wrong) has more.

## Hardware

General support for current x86-64 laptops and desktops, and in-depth tuning for the Lenovo ThinkPad P1 Gen 4i, where every release is tried first. [Hardware support](docs/hardware.md) has the details.

## Working on Nova

```sh
make lint                              # shellcheck, luac, qmllint, actionlint, the name check
make test                              # the unit tests
cargo test                             # the Rust parts
make DESTDIR=/tmp/nova-root install    # the nova package's files, into a scratch root
tools/build-site --out /tmp/site       # the site, with every link checked
```

`make install` draws Nova's cursor theme, with `librsvg`, `xorg-xcursorgen` and `hyprcursor` installed. Packages and ISOs are built only by CI. Start with [the architecture](docs/ARCHITECTURE.md); [the documentation's index](docs/README.md) lists the rest. The pictures are of the shell itself, taken by `tools/screenshots` on a Hyprland of their own (the windows float there to leave the background in view; Nova tiles them). The site (`site/`) is published from main by `.github/workflows/pages.yml`.

## License

MIT, see [LICENSE](LICENSE). [NOTICE](NOTICE) has the licenses of the code Nova builds on.
