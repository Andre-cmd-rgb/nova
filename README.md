# thinkpad-power

AC/battery power management for a hybrid-graphics Omarchy laptop. One command
sets it up; unplugging then takes the discrete GPU off the PCI bus and drops to
`power-saver`, and plugging in brings it back and goes to `performance`.

```bash
./install.sh              # set it up
./install.sh --uninstall  # put everything back
```

## The problem it solves

On a laptop whose panel hangs off the integrated GPU, the discrete card renders
nothing on the desktop and still bills several watts simply for being bound. An
RTX A2000 idles at about **6 W** — a large share of the total draw, and of the
runtime, on a 74 Wh battery.

Runtime power management cannot fix that on its own. NVIDIA's RTD3 is happy to
park the card, but only while nothing holds it open, and on a stock Omarchy
install three things do:

- **Hyprland** enumerates every DRM device and opens the discrete one.
- **Omarchy's `nvidia.lua`** sets `LIBVA_DRIVER_NAME=nvidia` and
  `__GLX_VENDOR_LIBRARY_NAME=nvidia` whenever an NVIDIA is present, so ordinary
  apps — a browser playing video, a GTK app — reach for the discrete card too.
- Anything already running that picked it up.

So the card never sleeps. This tool stops the desktop reaching for it, and then
removes it from the bus outright on battery, which is the only way to reach
zero.

`supergfxctl` is the usual answer and is a poor fit here: its `Integrated` mode
wants a reboot each way, and on non-ASUS hardware (`hotplug_type: None`) the
switch frequently does not stick. The installer stands it down.

## What it changes

| Where | What | Why |
|---|---|---|
| `/usr/local/bin/thinkpad-power` | the policy script | run by udev, boot, and resume |
| `/usr/local/bin/thinkpad-power` | manual toggle | what the menu entry runs |
| `/etc/thinkpad-power.conf` | the detected GPU address | so it can be found once removed |
| `/etc/systemd/system/thinkpad-power.service` | oneshot | applies the policy |
| `/etc/udev/rules.d/99-thinkpad-power.rules` | mains plug/unplug | triggers the above |
| `~/.config/uwsm/env-hyprland` | `AQ_DRM_DEVICES` | pins the compositor to the iGPU |
| `~/.config/hypr/hyprland.lua` | `LIBVA_DRIVER_NAME=iHD`, `__GLX_VENDOR_LIBRARY_NAME=mesa` | stops apps reaching for the dGPU |
| `~/.config/omarchy/extensions/omarchy-menu.jsonc` | overrides the GPU menu entry | live toggle instead of a reboot |
| supergfxd | disabled, package removed | it fights this and cannot switch reliably here |

It refuses to install if the connected panel is driven by the NVIDIA card,
because powering that off would black out the screen.

## Using it

```bash
thinkpad-power status      # power source, whether the card is on the bus,
                               # what holds it, current profile, live draw
prime-run <program>            # run something on the discrete GPU
```

Steam: put `prime-run %command%` in a game's launch options. NVENC and CUDA
work the same way — the card wakes when a context opens.

**Super+Space → Discrete GPU** toggles it by hand. That lasts until the next
plug or unplug, when the automatic policy applies again.

The card will not be powered off while a program is using it; the tool says
which PIDs are holding it rather than pulling the GPU out from under them.

## After installing

Log out and back in. The compositor reads its device list once at startup, so
until then Hyprland still holds the card open and it cannot be removed.

If a login ever fails to bring the screen back, switch to a TTY with
`Ctrl+Alt+F2` and run `rm ~/.config/uwsm/env-hyprland`, which undoes the GPU
pin, then log in again.

## License

MIT — see [LICENSE](LICENSE).
