# Readouts

`nova.cpu`, `nova.graphics` and `nova.memory`: a glyph and a percentage on the
bar, for how busy the processor and the graphics card are and how much memory
is in use. Each is off until it is switched on, in Settings → Menu Bar or
with `nova bar put nova.cpu`; a click opens `btop`, Nova's system monitor, in
a terminal (or goes to its window).

| File | What it is |
|---|---|
| `Service.qml` | `nova.readouts`: reads for every readout at once |
| `Readouts.js` | The arithmetic and the choice of card, apart so the tests reach them |
| `bin/drm-cards` | Lists the graphics cards, one line each |
| `ReadoutWidget.qml` | What the three widgets share: the look, the tooltip, the click |
| `Cpu.qml`, `Graphics.qml`, `Memory.qml` | The widgets, each with its `.manifest.json` |

## What it costs

Nothing while no readout is on a bar. A readout holds its part of the service
as long as it is in a bar's layout (a bar on each screen counts each), and the
service reads only the parts held, every two seconds, and not while the screen
is locked or dark. A number is set only when its whole percentage changes.

- CPU: the first line of `/proc/stat`; busy is all but idle and iowait.
- Memory: `/proc/meminfo`, `MemTotal` less `MemAvailable`; the tooltip says
  "7.4 of 31 GB in use". That is `free`'s "used", fastfetch's, and btop's,
  which a click opens: one number everywhere, and the one that reaches the
  total when the memory is full. Part of it is no program's: the kernel's
  reserve and the cache it counts as needed (about 0.6 GiB at rest on a
  32 GB computer, 2 GiB before `nova-memory-reserve`). `nova-doctor-memory`
  prints what the figure is made of.
- Graphics: the card with a connected screen. An Intel card (`i915`, with the
  older `power/rc6_residency_ms` too, or `xe`) is busy for the time it did not
  spend asleep (RC6 residency), over the time that passed; an AMD card's
  `gpu_busy_percent` is the share itself.

## A second graphics card

A discrete card that sleeps to save power is woken by almost anything that
reads from it, and stays awake, which costs battery. `bin/drm-cards` reads
only the name of its driver (a link) and its `power/runtime_status`, and the
tooltip says "NVIDIA graphics card: off" or "on" from that alone. It never
opens a device node, runs `nvidia-smi` or loads NVML, and reads no file of a
card that is asleep. The look at the cards is made when a readout first comes
and as the pointer comes onto Graphics, not on a timer.
