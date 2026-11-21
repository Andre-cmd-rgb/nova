# Power and battery

What Nova does with power on a laptop: power modes, sleep, the discrete GPU and the undervolt. `nova power` shows what it is doing now, and Settings → Performance and Battery hold the switches.

## Power modes

- **Plugged in, it is always full power.**
- **On battery, the battery comes first.** Every unplug starts in Power Saver. A mode you pick (the menu's Power Mode, Settings → Performance, or `nova power profile set balanced`) lasts until the next plug-in.

## Sleep

- Closing the lid suspends. **After two hours asleep on battery the computer hibernates**, so it does not drain in a bag; plugged in it never hibernates. At the battery's last 2% it hibernates at once.
- Settings → Battery sets what a closed lid does while plugged in, what the power button does, and how long before hibernating:

```sh
nova power lid lock            # plugged in, a closed lid locks and the computer keeps running
nova power button sleep        # the power button sleeps (menu, the default; or off)
nova power hibernate 4h        # hibernate after four hours asleep on battery (or never)
```

Waking from hibernation is a full start, which is why Nova keeps the start short.

## The discrete GPU

On a laptop with an NVIDIA card beside the integrated graphics:

- **The card sleeps while nothing uses it**: RTX 30 series and newer by themselves; for GTX 16 and RTX 20, `nova doctor` gives the one line that allows it.
- **`nova power run <program>`** starts one program on it. A game whose desktop entry asks for the discrete GPU (Steam's does) starts on it when opened from the menu or the App Center.

On the ThinkPad P1 Gen 4i Nova goes further, as sleeping still costs that card several watts:

- **On battery the card is taken off the PCI bus**, and comes back when plugged in. A game started plugged in keeps the card until it closes.
- **Settings → Performance → Discrete GPU**: On When Plugged In (the default) or Always Off. The menu's Toggle → Discrete GPU switches it by hand until the next plug-in.
- A card in use by a program is never pulled away: `nova power gpu` names what holds it.
- Other apps, Flatpak's too, stay on the integrated graphics.

## The governor

On the P1 Gen 4i, `nova-powerd` also sets the CPU's power limits, the integrated GPU's clocks and the fans to the load. A browser stays cool and quiet; a long compile climbs, within about a minute, to everything the battery's mode allows. Power Saver keeps to the lowest tier.

```sh
nova power status -v           # the tier, the limits, the fans, the draw
sudo nova power boost 60       # lift the battery caps for an hour, for a build
```

It starts only on models whose tiers have been measured, which today is the P1. Its tiers, fan curves and tunables are in the [power code's notes](../src/power/README.md).

## Undervolting

`nova power undervolt` lowers an Intel CPU's voltage by an offset you have tested: less heat for the same speed. It works only where the firmware lets it; on most business laptops it is locked, and the command says so.

```sh
nova power undervolt set -70       # the core and the cache, in mV; asks for your password
nova power undervolt set -80 -70   # the core's offset, then the cache's
nova power undervolt               # what is set, and whether the CPU took it
nova power undervolt off
```

Settings → Performance has a slider for each. Find the depth with a stress test that checks its own results, and stay a step short of the first machine check. The first machine check takes the undervolt off, and so does a start after a crash while it was on; it stays off until `nova power undervolt on`.

## What uses the power

`sudo nova power doctor` names what keeps the computer out of its deepest idle state: devices that never sleep, the package C-states, the panel's self-refresh. `powertop` covers the rest.

| Command | Does |
|---|---|
| `nova power` | the power source, the discrete GPU and the draw |
| `nova power profile get`, `set <mode>` | the battery's power mode |
| `nova power run <program>` | one program on the discrete GPU |
| `nova power gpu [toggle\|mode auto\|off]` | the P1's discrete GPU on or off |
| `nova power lid`, `button`, `hibernate` | what the lid and the button do, when it hibernates |
| `nova power undervolt` | the CPU's voltage offset |
| `sudo nova power boost [minutes\|off]` | lift the battery caps for a while (the P1's governor) |
| `sudo nova power doctor` | what keeps the computer awake |
