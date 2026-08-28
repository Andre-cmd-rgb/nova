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
| `/etc/mkinitcpio.conf.d/nvidia.conf` | **`--boot-path` only.** emptied, original kept alongside | the driver dragged 109 MB of GSP firmware into every initramfs |
| `systemd-tpm2-setup{,-early}` | **`--boot-path` only.** masked, and only with no LUKS and no pcrlock | 4.1 s per boot provisioning a key nothing reads |

It refuses to install if the connected panel is driven by the NVIDIA card,
because powering that off would black out the screen.

The last two are **opt-in**, and off unless you ask for them:

```
./install.sh --boot-path
```

Everything else in the table is reversible from a running session. These two
are not — they change what boots, which is a different kind of risk from a
power tunable, so they are opt-in for the same reason `ASPM_ON_BAT` is. They
take effect at the next boot, and the installer rebuilds the initramfs for you.
`--uninstall` puts both back and rebuilds again, whether or not the run that
removes them passed the flag.

The boot they were measured against, at 32 s from the power button:

| stage | before | |
|---|---|---|
| firmware POST | 11.50 s | BIOS setup only, nothing here touches it |
| boot loader | 9.11 s | reads the whole UKI off vfat; follows its size |
| kernel + initramfs | ~5.7 s | |
| userspace to `graphical.target` | 6.02 s | 4.1 s of it TPM provisioning |

Masking the TPM units takes a known 4.1 s off the userspace figure. What
emptying the initramfs is worth is **not yet measured** — the reasoning is that
the loader stage is dominated by reading a UKI carrying 109 MB of firmware it
never uses, but that is an inference from size, and only the next boot settles
it.

`sudo thinkpad-power doctor` prints the first two figures after each boot, so
the answer arrives on its own. They come from the loader's own
`LoaderTime*USec` efivars rather than `systemd-analyze`, whose split is skewed
here by a printk clock that starts at ~6.7 s.

## Using it

```
thinkpad-power <command> [args]

  status [-v]         power source and discrete GPU; -v adds diagnostics
  doctor              what is keeping this machine awake (root)
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

`status` answers the question you asked in three lines; `-v` adds the
diagnostics. Rows that have nothing to say are left out — `held by` appears
only when something is actually holding the card, and `left on bus` only if a
PCI function of it somehow survived being removed.

```
$ thinkpad-power status

  power source   battery (power-saver)
  discrete GPU   off
  draw           12.94 W

$ thinkpad-power status -v

  power source   battery (power-saver)
  discrete GPU   off
  draw           12.94 W

  address        0000:01:00.0
  functions      none on the bus
  driver load    blocked
  runtime pm     8 devices set to auto
  pcie aspm      default
```

Use `thinkpad-power run`, not `prime-run`. The session hides NVIDIA's EGL
vendor and Vulkan ICD so nothing reaches for the card by accident, and
`prime-run` does not know to put those back; `thinkpad-power run` restores them
for that one process and adds the usual offload hints.

Steam: put `thinkpad-power run %command%` in a game's launch options.

**Super+Space → Discrete GPU** toggles it by hand, and says only what it did:

```
  The discrete GPU is on. Turn it off? [y/N]

  The discrete GPU is now off.
```

That lasts until the next plug or unplug, when the automatic policy applies
again — and turning the card *on* while on battery says so, because the retry
timer will switch it back off within two minutes.

The card will not be powered off while a program is using it; the tool names
what is holding it rather than pulling the GPU out from under it.

## Tunables

Beyond the GPU, the battery policy sets runtime power management to `auto` on
PCI devices whose drivers left them pinned at `on`, and lets the HDA codec
sleep between sounds. Note that `auto` grants permission to suspend; whether a
device takes it is up to its driver, and a busy one will stay awake. Both are reverted on AC — the runtime PM changes are recorded
in `/run`, so only the devices this tool actually changed are put back, rather
than forcing the whole bus to `on` and overriding choices the drivers made at
boot.

Three further knobs are **opt-in**, in `/etc/thinkpad-power.conf`:

```sh
PL1_ON_BAT=30                # sustained CPU power limit on battery, in watts
ASPM_ON_BAT=powersave        # or powersupersave, which adds the L1 substates
NMI_WATCHDOG_ON_BAT=off      # disable the lockup detector on battery
```

**`PL1_ON_BAT` is the one that changes anything under load.** Firmware here
leaves the sustained limit at the AC figure on battery — 109 W on the machine
this was written for, against a 45 W part — so a busy browser is free to empty
the battery as fast as the cooling allows. Capping it is safe in the way
undervolting is not: the worst case is a slower CPU, not an unstable one.

PL1 is an *average over a time window*, and the firmware sets that window to
56 seconds, so a burst lasting most of a minute escapes the cap entirely.
Setting `PL1_ON_BAT` therefore also shortens the window to 10 s; both values
are restored on AC. Check `thinkpad-power status -v` afterwards — it prints
the limit and the window, and DPTF drives the same registers, so it is worth
confirming rather than assuming.

`ASPM_ON_BAT` is off by default because forcing L0s/L1 on every link can upset
a device that is merely ASPM-tolerant, and the symptom is a hang.
`NMI_WATCHDOG_ON_BAT` saves very little and costs you the hard-lockup
detector.

### Finding the rest of the watts

`sudo thinkpad-power doctor` reads the platform controller's latency-tolerance
table, the package C-state residency, whether the panel is self-refreshing,
and which PCI devices never sleep. The LTR table is the useful part: an IP
block advertising a short latency tolerance forbids the platform from entering
its deep package states, and the table names it.

On the machine this was written for the answer was undramatic. xHCI advertises
500 µs — that is the Bluetooth mouse. The audio controller advertises 364 µs,
but only while something is playing; it is suspended otherwise. Panel Self
Refresh was already enabled (PSR1; the panel does not support PSR2 or Panel
Replay, so there is nothing further to switch on). Hardware video decode was
already working. Package C2 sat above half the time not through
misconfiguration but because a wireless mouse, a connected 5G modem, an NVMe
and a Wi-Fi card were all in use.

That is the usual shape of this exercise: the large win is the discrete GPU,
the second is the power limit under load, and the rest is a catalogue of
things that are awake because you are using them.

### On undervolting

There isn't one, and on this hardware there cannot be. Undervolting an
11th-gen mobile part goes through the overclocking mailbox at MSR `0x150`,
gated in microcode after Plundervolt (CVE-2019-11157) and locked by vendor
firmware on business laptops. Measured on a P1 Gen 4i, i7-11850H, microcode
`0x58`: writing a −5 mV offset to the CPU-core plane and reading it back
returns **+0.0 mV**. The mailbox does not fault — it accepts the write and
discards it, which is the silent-ignore form of the lock. (Plane 3 answers
command `0x10` with status `0x5`, so the mailbox is alive and responding; it
simply will not take offsets.)

That result matters for the AC/DC loadline trick too, which is often suggested
as a way around a locked undervolt. It is not: it is a *different command to
the same mailbox*, behind the same lock. If offsets are discarded, loadline
writes are discarded.

Worth testing rather than assuming, though, and worth testing correctly — a
zero-offset write that reads back zero proves nothing, because a locked
mailbox returns exactly that. Only a non-zero round trip distinguishes
"accepted" from "silently discarded".

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

## Tests

```bash
./test/roundtrip.sh
```

No root and no sysfs: it extracts the library half of the script, points the
tunables at temporary files and drives each battery -> AC round trip, checking
that the firmware's value is saved and restored and that a nonsense wattage is
refused rather than written to a register that governs package power. The
runtime-PM state file was silently truncated on every battery run for a while,
so AC had nothing to put back; that is the class of bug this catches.

## License

MIT — see [LICENSE](LICENSE).
