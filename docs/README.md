# Nova's documentation

The pages below are split between using Nova and working on it.

## Using Nova

| Page | For |
|---|---|
| [Installing Nova](install.md) | the USB stick, the installer's questions, encryption, the offline stick, carrying files over, a portable Nova |
| [Using Nova](using.md) | the keys, the menu, the bar, Settings page by page, the calendar, dictation, Caffeine, apps, the keyboard |
| [Themes and backgrounds](themes.md) | themes, the adaptive theme, backgrounds, the see-through bar, the font, a theme of your own |
| [Updates and going back](updates.md) | how updates work, release candidates, snapshots, when something goes wrong |
| [Hardware support](hardware.md) | what Nova runs on, what the installer picks, what a laptop gets, what the P1 Gen 4i gets |
| [Patches](patches.md) | fixes for one computer's faults, such as bad memory, kept across reinstalls |
| [The power governor](power.md) | `nova power` on the ThinkPad P1 Gen 4i: the discrete GPU, the CPU's limits, the fans, the undervolt |

## Working on Nova

| Page | For |
|---|---|
| [Architecture](ARCHITECTURE.md) | the contract every component follows: where things install, names and paths, the session, the theme, power, packaging, the code rules |
| [The shell](../src/shell/README.md) and [its plugins](../src/shell/plugins/README.md) | the bar, the panels, the lock screen, and writing a plugin |
| [The power governor's code](../src/power/README.md) | where `nova power` lives in the source |
| [ThinkPad P1 Gen 4i](hardware/thinkpad-p1-gen4i.md) | the numbered facts measured on it, which the code cites |
| [Packaging](packaging.md) | the packages Nova builds, and keeping each one up to date |
| [Releasing](releasing.md) | versions, the signing key, the package bucket, the two-week cycle, the hardware checklist |

The pictures in `images/` are taken of the shell by `tools/screenshots`, over `images/dusk.svg`, which `tools/draw-dusk` draws.
