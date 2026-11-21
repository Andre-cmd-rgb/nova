# Nova's documentation

New to Nova, or to a tiling desktop? Read [Installing Nova](install.md), then the first part of [Using Nova](using.md). Everything else is here when you need it.

## Using Nova

| Page | For |
|---|---|
| [Installing Nova](install.md) | the USB stick, the installer's questions, encryption, carrying files over, a portable Nova |
| [Using Nova](using.md) | the first minutes, the menu, the bar, Settings, and the everyday parts of the desktop |
| [Keys and commands](keys.md) | every key, and the `nova` command's groups |
| [Updates and going back](updates.md) | updates, release candidates, snapshots, when something goes wrong |
| [The App Center](apps.md) | installing and removing apps, where they come from, games |
| [Themes and backgrounds](themes.md) | themes, the adaptive theme, backgrounds, fonts, a theme of your own |
| [AirDrop](airdrop.md) | photos and files from an iPhone, and to one |
| [iPhone notifications](iphone.md) | an iPhone's notifications on the computer |
| [Hardware support](hardware.md) | what Nova runs on, what a laptop gets, tuned devices |
| [Power and battery](power.md) | power modes, sleep, the discrete GPU, the undervolt |
| [Patches](patches.md) | fixes for one computer's faults, kept across reinstalls |

## Working on Nova

| Page | For |
|---|---|
| [Architecture](ARCHITECTURE.md) | the contract every component follows: where things install, names, the session, the theme, power, packaging, the code rules |
| [The shell](../src/shell/README.md) and [its plugins](../src/shell/plugins/README.md) | the bar, the panels, the lock screen, and writing a plugin |
| [The power governor](../src/power/README.md) | `nova power`'s code, tunables, tiers and fans |
| [AirDrop](../src/airdrop/README.md), [iPhone notifications](../src/iphone/README.md), [the App Center](../src/apps/README.md) | how each is built and tested |
| [ThinkPad P1 Gen 4i](hardware/thinkpad-p1-gen4i.md) | the numbered facts measured on it, which the code cites |
| [Packaging](packaging.md) | the packages Nova builds, and keeping each up to date |
| [Releasing](releasing.md) | versions, the signing key, the package bucket, the two-week cycle |

The user pages are also [the site's](https://andre-cmd-rgb.github.io/nova/docs/): `tools/build-site` renders them into the site's look and fails on a link, a heading or a picture that leads nowhere. A new user page goes into the list at the top of `tools/build-site`. The pictures in `images/` are taken of the shell itself by `tools/screenshots`, over `images/dusk.svg`, which `tools/draw-dusk` draws.
