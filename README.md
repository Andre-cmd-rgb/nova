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
- **GLVND** loads every EGL vendor it finds, so `libEGL_nvidia` ends up inside
  the compositor itself — pinning the DRM device does not prevent this, because
  it decides which card draws the screen, not which driver the libraries load.
- **The Vulkan loader** loads every ICD it finds, so any GTK4 app (GTK renders
  with Vulkan) opens `/dev/nvidia0`, `/dev/nvidiactl` and `/dev/nvidia-modeset`
  just by starting.
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
| `/etc/udev/rules.d/98-thinkpad-power-igpu.rules` | `/dev/dri/igpu` symlink | a stable, colon-free name for the iGPU |
| `~/.config/uwsm/env-hyprland` | `AQ_DRM_DEVICES=/dev/dri/igpu` | pins the compositor to the iGPU |
| `~/.config/uwsm/env-hyprland` | `__EGL_VENDOR_LIBRARY_FILENAMES` | hides the NVIDIA EGL vendor from the session |
| `~/.config/uwsm/env-hyprland` | `VK_LOADER_DRIVERS_DISABLE=*nvidia*` | hides the NVIDIA Vulkan ICD from the session |
| `~/.config/hypr/hyprland.lua` | `LIBVA_DRIVER_NAME=iHD`, `__GLX_VENDOR_LIBRARY_NAME=mesa` | stops apps reaching for the dGPU |
| `~/.config/omarchy/extensions/omarchy-menu.jsonc` | overrides the GPU menu entry | live toggle instead of a reboot |
| `/etc/systemd/system/thinkpad-power-gpu.{service,timer}` | retry every 2 min | a plug event is one edge that never repeats |
| `/run/modprobe.d/thinkpad-power-nvidia.conf` | blocks the nvidia modules | while the card is off the bus, only then |
| supergfxd | disabled, package removed | it fights this and cannot switch reliably here |

It refuses to install if the connected panel is driven by the NVIDIA card,
because powering that off would black out the screen.

## Using it

```
thinkpad-power <command> [args]

  status              power source, discrete GPU state, active tunables
  switch              turn the discrete GPU on or off, interactively
  run <cmd> [args]    run one program on the discrete GPU

  auto                apply the policy for the current power source
  ac, battery         force one side of the policy
  gpu-auto            the GPU half of the policy only
  gpu-on, gpu-off     put the discrete GPU on or off the PCI bus
  gpu-toggle          whichever it is not
```

`status`, `switch` and `run` need no privileges; everything else requires
root. `status` is side-effect free — in particular it does not call
`nvidia-smi`, which would wake the card out of P8 just to answer.

```
$ thinkpad-power status

  power source   battery
  power profile  power-saver
  draw           13.51 W

  discrete GPU   off the bus
  driver load    blocked

  runtime pm     8 devices set to auto
  pcie aspm      default
```

Use `thinkpad-power run`, not `prime-run`. The session hides NVIDIA's EGL
vendor and Vulkan ICD so nothing reaches for the card by accident, and
`prime-run` does not know to put those back; `thinkpad-power run` restores them
for that one process and adds the usual offload hints.

Steam: put `thinkpad-power run %command%` in a game's launch options.

**Super+Space → Discrete GPU** toggles it by hand. That lasts until the next
plug or unplug, when the automatic policy applies again.

The card will not be powered off while a program is using it; the tool says
which PIDs are holding it rather than pulling the GPU out from under them.

## Tunables

Beyond the GPU, the battery policy sets runtime power management to `auto` on
PCI devices whose drivers left them pinned at `on`, and lets the HDA codec
sleep between sounds. Note that `auto` grants permission to suspend; whether a
device takes it is up to its driver, and a busy one will stay awake. Both are reverted on AC — the runtime PM changes are recorded
in `/run`, so only the devices this tool actually changed are put back, rather
than forcing the whole bus to `on` and overriding choices the drivers made at
boot.

PCIe ASPM is **opt-in**, because forcing L0s/L1 on every link can upset a
device that is merely ASPM-tolerant and the symptom is a hang:

```sh
# /etc/thinkpad-power.conf
ASPM_ON_BAT=powersave        # or powersupersave, which adds the L1 substates
```

## What to expect

Numbers depend entirely on the machine, the panel and what is running, so
treat the following as one worked example rather than a promise. On the
ThinkPad P1 Gen 4i this was built for — RTX A2000, 3840x2400 panel — with the
screen at 30% and a light desktop:

| | draw |
|---|---|
| discrete GPU bound and idle | ~26 W |
| discrete GPU off the bus | ~20 W |

The card is worth about 6 W of that, which on a 74 Wh battery is roughly the
difference between 2.3 and 3.0 hours. The tunables are worth a fraction of a
watt between them.

They are also not where the remaining watts are. On that machine the panel and
the browser dominate, and a connected 5G modem costs more than every kernel
knob in this tool put together. `powertop` will tell you which of those applies
to yours; this tool deliberately does not guess.

## Why a symlink, and why it matters

`AQ_DRM_DEVICES` takes a `:`-separated list, so **the value cannot contain a
colon** — which rules out `/dev/dri/by-path/pci-0000:00:02.0-card`, since PCI
addresses are full of them. Aquamarine splits such a path into fragments,
matches none of them against the cards udev enumerated, reports "Found no gpus
to use", and the compositor exits before you have a session. Card numbering
(`/dev/dri/cardN`) is not stable across boots either.

So the installer adds the udev rule the Hyprland wiki recommends for this, giving
a stable colon-free `/dev/dri/igpu`, checks that the symlink actually appeared
before writing the pin, and the pin itself is guarded at every login:

```sh
if [ -e /dev/dri/igpu ] && grep -qx connected /sys/class/drm/$(basename $(readlink -f /dev/dri/igpu))-*/status; then
  export AQ_DRM_DEVICES=/dev/dri/igpu
fi
```

If the card is missing, or is not the one driving a connected screen, nothing
is set and the session starts normally on both GPUs. The worst case is that the
discrete card keeps being held open — never that you cannot log in.

## After installing

Log out and back in. The compositor reads its device list once at startup, so
until then Hyprland still holds the card open and it cannot be removed.

If a login ever fails to bring the screen back, switch to a TTY with
`Ctrl+Alt+F2` and run `rm ~/.config/uwsm/env-hyprland`, which undoes the GPU
pin, then log in again.

## License

MIT — see [LICENSE](LICENSE).
