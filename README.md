# nova

A small, fast Arch Linux desktop: Hyprland, a Quickshell shell, one `nova` command and
a power manager that knows your laptop. It boots from the firmware logo straight to the
lock screen, uses one theme across every surface, and installs from a USB stick that can
carry your files over.

> **Status:** `v1.0.0-beta.1` in progress. Supported hardware: Lenovo ThinkPad P1 Gen 4i
> and Lenovo Legion 5 (13th-gen Intel + RTX 4070). Other x86-64-v3 machines with Intel
> graphics should work but are untested.

## Install

On any Arch-based system (Omarchy included), download `nova-usb` from the
[latest release](https://github.com/Andre-cmd-rgb/nova/releases) and run it:

```sh
bash nova-usb
```

It downloads the installer, writes it to a USB stick, and can bring your things
along, encrypted: SSH and GnuPG keys, Chrome signed in, VS Code, Claude Code,
git repositories, folders, Wi-Fi networks, your extra packages. Boot the stick,
type its passphrase, and the installer puts everything back. On Nova itself it
is `nova usb`.

- [Architecture](docs/ARCHITECTURE.md): how the pieces fit, and the rules for adding code
- [NOTICE](NOTICE): Nova's shell, Hyprland defaults and palettes derive from Omarchy (MIT)

## License

MIT, see [LICENSE](LICENSE).
