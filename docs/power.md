# Nova's power governor: the manual

`nova power` is Nova's power governor. Its policy half, `nova-power`, takes
the discrete GPU off the PCI bus on battery and brings it back plugged in; its
continuous half, `nova-powerd`, sets the CPU's limits and the fans to the load
(below). Settings → Performance shows what it is doing, and holds the switches.
(The power mode follows the power source too, power-saver on battery and
performance on AC until you pick another, but that is `nova-power-profile`'s,
not the governor's.) It is part of the `nova` package; its tiers and limits
are measured on the ThinkPad P1 Gen 4i, and until another model's are, it is
inert on any other computer. The top of
[thinkpad-p1-gen4i.md](hardware/thinkpad-p1-gen4i.md) lists where each piece
installs, and [src/power/README.md](../src/power/README.md) where its code is.

## The problem it solves

On a laptop whose panel hangs off the integrated GPU, the discrete card renders
nothing on the desktop and still bills several watts simply for being bound. An
RTX A2000 idles at about **6 W** — a large share of the total draw, and of the
runtime, on a 74 Wh battery.

Runtime power management cannot fix that on its own. NVIDIA's RTD3 is happy to
park the card, but only while nothing holds it open, and on a stock install
these do:

- **Hyprland** enumerates every DRM device and opens the discrete one.
- **GLVND** loads every EGL vendor it finds, so `libEGL_nvidia` ends up inside
  the compositor itself — pinning the DRM device does not prevent this, because
  it decides which card draws the screen, not which driver the libraries load.
- **The Vulkan loader** loads every ICD it finds, so any GTK4 app (GTK renders
  with Vulkan) opens `/dev/nvidia0`, `/dev/nvidiactl` and `/dev/nvidia-modeset`
  just by starting.
- **Common NVIDIA setups** set
  `LIBVA_DRIVER_NAME=nvidia` and `__GLX_VENDOR_LIBRARY_NAME=nvidia` whenever
  an NVIDIA is present, so ordinary apps — a browser playing video, a GTK
  app — reach for the discrete card too.
- Anything already running that picked it up.

So the card never sleeps. Nova stops the desktop reaching for it, and then
removes it from the bus outright on battery, which is the only way to reach
zero.

`supergfxctl` is the usual answer and is a poor fit here: its `Integrated` mode
wants a reboot each way, and on non-ASUS hardware (`hotplug_type: None`) the
switch frequently does not stick. Nova does not install it.

## The compositor's GPU, by a symlink

The compositor is pinned to the iGPU with `AQ_DRM_DEVICES`, which takes a
`:`-separated list, so **the value cannot contain a colon** — which rules out
`/dev/dri/by-path/pci-0000:00:02.0-card`, since PCI addresses are full of them.
Aquamarine splits such a path into fragments, matches none of them against the
cards udev enumerated, reports "Found no gpus to use", and the compositor exits
before you have a session. Card numbering (`/dev/dri/cardN`) is not stable
across boots either.

So Nova ships the udev rule the Hyprland wiki recommends for this
(`98-nova-igpu.rules`), giving a stable colon-free `/dev/dri/igpu`, and the
session's environment (`20-nova-thinkpad-p1-gen4i` in uwsm's `env.d`) sets the
pin only when that card really drives a connected panel. If it does not,
nothing is set and the session starts normally on both GPUs. The worst case is
that the discrete card keeps being held open, never that you cannot log in.

## The boot

Two things are left out of every Nova boot: NVIDIA firmware in the initramfs
(the driver dragged 109 MB of GSP firmware into every image, and the loader
reads the whole UKI off vfat), and TPM key provisioning (4.1 s of every boot
for a key nothing reads, on a disk Nova does not encrypt). The boot they were
measured against, at 32 s from the power button:

| stage | before | |
|---|---|---|
| firmware POST | 11.50 s | BIOS setup only, nothing here touches it |
| boot loader | 9.11 s | reads the whole UKI off vfat; follows its size |
| kernel + initramfs | ~5.7 s | |
| userspace to `graphical.target` | 6.02 s | 4.1 s of it TPM provisioning |

`sudo nova power doctor` prints the first two figures after each boot. They
come from the loader's own `LoaderTime*USec` efivars rather than
`systemd-analyze`, whose split is skewed here by a printk clock that starts at
~6.7 s.

## Using it

```
usage: nova power [command] [args]

  status [-v]         power source and discrete GPU, the default; -v adds diagnostics
  status --json       the governor, limits, fans and draw, for Settings
  doctor              what is keeping this machine awake (root)
  switch              turn the discrete GPU on or off, interactively
  run <cmd> [args]    run one program on the discrete GPU

  boost [min|off]     lift the battery CPU caps for a while (default 30 min)
  daemon-stopped      restore what nova-powerd owned (systemd runs this)

  auto                apply the policy for the current power source
  post-hibernate      rescan the bus, then apply the policy (resume hook)
  ac, battery         force one side of the policy
  gpu-auto            the GPU half of the policy only
  gpu-on, gpu-off     put the discrete GPU on or off the PCI bus
  gpu-toggle          whichever it is not
  gpu-mode [auto|off] print or set the policy for the card: auto puts it on
                      with AC and off on battery, off keeps it off on both
```

`status`, `switch`, `run` and a bare `gpu-mode` need no privileges; everything
else requires root. `status` is side-effect free — in particular it does not call
`nvidia-smi`, which would wake the card out of P8 just to answer.

`status` answers the question you asked in three lines; `-v` adds the
diagnostics. Rows that have nothing to say are left out — `held by` appears
only when something is actually holding the card, and `left on bus` only if a
PCI function of it somehow survived being removed.

```
$ nova power status

  power source   battery (power-saver)
  discrete GPU   off
  draw           12.94 W

$ nova power status -v

  power source   battery (power-saver)
  discrete GPU   off
  draw           12.94 W

  address        0000:01:00.0
  functions      none on the bus
  driver load    blocked
  runtime pm     8 devices set to auto
  pcie aspm      default
```

Use `nova power run`, not `prime-run`. The session hides NVIDIA's EGL
vendor and Vulkan ICD so nothing reaches for the card by accident, and
`prime-run` does not know to put those back; `nova power run` restores them
for that one process and adds the usual offload hints.

Steam: put `nova power run %command%` in a game's launch options.

**Super+Space → Toggle → Discrete GPU** toggles it by hand, and says only what
it did:

```
  The discrete GPU is on. Turn it off? [y/N]

  The discrete GPU is now off.
```

A card turned off by hand comes back at the next plug-in. One turned on by
hand when the policy wants it off stays on until the charger is next plugged
in, or a restart; the retry timer leaves it alone, and `status` says so.

**Settings → Performance → Discrete GPU** picks the policy, kept in
`/var/lib/nova/gpu-mode`: *On When Plugged In* (`auto`, the default) or
*Always Off* (`off`), for a cooler, quieter machine at the desk.
`nova power gpu mode off` does the same from a terminal.

The card will not be powered off while a program is using it; `nova power`
names what is holding it rather than pulling the GPU out from under it.

## Sleep

S3 on this machine costs **1.26 W**, measured over a 63 minute suspend. A full
74.5 Wh battery is therefore gone in about **59 hours**. A closed lid does not
survive a long weekend.

What a MacBook does is two things, not one: sleep to RAM, and then after a few
hours write RAM to disk and cut power entirely. systemd calls that
`suspend-then-hibernate`, and it is how Nova sleeps: the installer makes the
swapfile and the `resume=` arguments, and the lid, the suspend key and the
menu's Suspend all ask for it (`data/systemd/sleep.conf.d`, overridable in
`/etc/systemd/sleep.conf.d/`).

| | |
|---|---|
| first 2 h | S3 at 1.26 W — instant wake, costs ~2.5 Wh |
| after that | hibernated: RTC only, days to weeks |
| on AC | plain suspend; `HibernateOnACPower=no`, against systemd's default of yes |
| battery at 2% | hibernates outright: UPower's critical action, set to `Hibernate` in `/etc/UPower/UPower.conf.d/10-nova.conf`, since S3 first would empty it |

**Resuming from hibernate is a full power cycle, so it costs a whole boot** —
which is why the boot is kept short. It is also why the discrete card
needs handling: firmware enumerates it again on the way up, but the restored
image was taken with it off the bus, so the kernel has no record of it, never
touches it, and it sits in D0 drawing what the policy exists to save. Nothing
would report that — `nova power auto` sees no device and says "already off
the bus". The resume hook rescans first, so the policy has something to remove.
It fires only on the hibernate half, keyed on `SYSTEMD_SLEEP_ACTION`: on an
ordinary S3 resume the card is correctly absent and a rescan would bring it
back only to take it away again, on every resume.

## Wake

Wake on this machine is not slow where it looks slow. Low-level resume to
`PM: suspend exit` is **188 ms**, and the lock screen is prompting **1.04 s**
after that. What is felt as five seconds is the fingerprint reader.

Two separate things happen to it across S3:

**It loses power and re-enumerates.** The lock screen starts its PAM
fingerprint session before that finishes and gets `device was disconnected`,
so it retries — four times in 900 ms here before the fourth caught a live
device.

Marking the reader wake-capable, so its port stays powered, was tried and is
**ruled out**. It works, in the narrow sense: the retries dropped from 4 to 1.
It also left the reader in a state fprintd refuses —
`Ignoring device due to initialization error: unsupported firmware version` —
so fingerprint unlock did not work at all on resume. Trading a working unlock
for 0.9 s is not a trade worth making, so there is no knob for it.

**It fails to match.** This is the larger half and no kernel knob touches it.
Enrolling one finger means a slightly-off placement fails; the measured resume
above spent 4.7 s waiting for a finger and then failed twice before the third
attempt authenticated, at 8.0 s. More enrolled fingers is the fix:

```
fprintd-enroll -f left-index-finger
fprintd-enroll -f right-thumb
```

Two other devices resume badly and are worth knowing about, though neither
gates the unlock: the 5G modem fails with `-22` and does a full recovery
cycle, and the Thunderbolt xHCI controller reinitialises, which makes usb1 and
usb2 report `root hub lost power or was reset`.

## Tunables

Beyond the GPU, the battery policy sets runtime power management to `auto` on
PCI devices whose drivers left them pinned at `on`, and lets the HDA codec
sleep between sounds. Note that `auto` grants permission to suspend; whether a
device takes it is up to its driver, and a busy one will stay awake. Both are
reverted on AC — the runtime PM changes are recorded in `/run`, so only the
devices the policy actually changed are put back, rather than forcing the whole
bus to `on` and overriding choices the drivers made at boot.

The battery policy also turns **Wi-Fi power save on**, and back off on AC.
Some distributions turn it off for every machine, and their reasons are good
ones: 20-300 ms latency spikes on an idle link, and Intel BE200/BE211 firmware that
drops the link outright when the radio naps. Neither applies on battery on the
P1 Gen 4i — the radio is an AX210, which is not one of the
parts with that firmware bug, and a page load and a video stream both buffer
through the latency. The hardware profile installs
`/etc/NetworkManager/conf.d/nova-hw-wifi-powersave.conf` with
`wifi.powersave = 1` ("ignore"), because NetworkManager otherwise rewrites the
flag at every connection activation and a roam or a resume would quietly undo
it. Set `WIFI_POWERSAVE_ON_BAT=off` to disagree.

The remaining knobs are **opt-in**, in `/etc/nova/power.conf`:

```sh
PL1_ON_BAT=30                # sustained CPU power limit on battery, in watts
PL2_ON_BAT=45                # burst limit; must be at least PL1_ON_BAT
CPU_MAX_PCT_ON_BAT=60        # frequency ceiling, percent of the P-state range
ASPM_ON_BAT=powersave        # or powersupersave, which adds the L1 substates
NMI_WATCHDOG_ON_BAT=off      # disable the lockup detector on battery
```

**`PL1_ON_BAT` is the one that changes anything under load.** Firmware here
leaves the sustained limit at the AC figure on battery — 109 W on the P1 Gen
4i, against a 45 W part — so a busy browser is free to empty
the battery as fast as the cooling allows. Capping it is safe in the way
undervolting is not: the worst case is a slower CPU, not an unstable one.

PL1 is an *average over a time window*, and the firmware sets that window to
56 seconds, so a burst lasting most of a minute escapes the cap entirely.
Setting `PL1_ON_BAT` therefore also shortens the window to 10 s; both values
are restored on AC. Check `nova power status -v` afterwards — it prints
the limit and the window, and DPTF drives the same registers, so it is worth
confirming rather than assuming.

**`PL2_ON_BAT` is the one you feel rather than measure.** PL2 governs the burst
before PL1's average catches up — 135 W here against a 45 W part, over a
2.44 ms window — so every page render is allowed a spike at three times TDP.
The energy in one burst is small; the heat is not, and it is where the fan
noise and the warm palm rest come from. Capping it makes the machine run cool
rather than merely last longer. It must be at least `PL1_ON_BAT`; a burst limit
below the sustained limit is a contradiction, and it is refused rather than
written.

**`CPU_MAX_PCT_ON_BAT` is the answer to "why is it hot when I am only reading a
web page".** Under HWP, `intel_pstate` will still walk to the top of the range
to scroll, and the last third of the frequency range costs disproportionately
more power than it returns in speed — this part reaches 4.8 GHz, and 57% of its
P-state range is turbo, so a ceiling below about 43 takes turbo off the table
entirely. It is a ceiling, not a target: nothing is slower until something
actually asks for more than the ceiling.

What *does* ask for it is a compile, which is what `boost` is for:

```sh
sudo nova power boost        # 30 minutes
sudo nova power boost 90     # or as long as the build takes
sudo nova power boost off    # early
```

It lifts both CPU caps for a bounded stretch (the governor's top tier, while
it runs) and schedules its own expiry through `systemd-run` before lifting
anything, so a boost that fails to schedule leaves the machine capped rather
than uncapped forever. The marker, `/run/nova-power.boost`, is read by both
halves, so it works whichever is managing the CPU, and a resume, a replug or
the retry timer cannot end a boost halfway through a build. `status -v` says when
one is active. The energy-performance preference and the platform profile are
*not* touched by any of this — those are power-profiles-daemon's, and two
things writing them means the last writer wins.

`ASPM_ON_BAT` is off by default because forcing L0s/L1 on every link can upset
a device that is merely ASPM-tolerant, and the symptom is a hang.
`NMI_WATCHDOG_ON_BAT` saves very little and costs you the hard-lockup
detector.

`thermald` is installed on this machine and deliberately not running. It drives
the same RAPL constraints the governor does, so leaving it off is what makes
`status -v` mean what it says.

## The governor

`nova-powerd` is the continuous half, and it exists because RAPL gives you
the opposite of what a laptop wants. PL1/PL2 is *high briefly, low sustained*:
a burst gets 135 W and a long job gets throttled. What is wanted is *low
briefly, high sustained* — a browser must never reach 4.8 GHz to scroll a page,
and a compile must have everything. No register does that, because it is a
policy about time, and a policy about time needs something awake to watch the
clock.

Four tiers on battery, and a ladder that gets harder to climb:

| tier | PL1 | PL2 | ceiling | iGPU | reached after |
|---|---|---|---|---|---|
| `light` | 12 W | 18 W | 45%, turbo off | 800 MHz | the default |
| `mid` | 18 W | 28 W | 70% | 1050 MHz | 8 s of load |
| `full` | 28 W | 42 W | 100% | free | 16 s more |
| `turbo` | 40 W | 60 W | 100% | free | 24 s more |

The dwell is the whole design. Climbing needs sustained load — longer at every
rung, so about a minute of unbroken work to reach the top, which nothing but a
real job produces. Falling needs 25 s of quiet, so the gaps between files in a
build do not cost a re-ramp. Between the two thresholds nothing moves at all,
which is what stops a load hovering on the line from oscillating. `iowait` is
not counted as busy: a build waiting on the NVMe is not asking for frequency.

**The ceiling is the lever; PL1 is the safety net.** Power goes roughly as
*f·V²* and V tracks f, so the top of the frequency curve costs several times
what it returns — 45% of 4.8 GHz is about 2.16 GHz, under the 2.5 GHz base
ratio, so turbo is unreachable before `no_turbo` even says so. PL1 is not set
lower on purpose: `intel-rapl:0` is the **package** domain, with `core` and
`uncore` beneath it, so the iGPU spends from the same budget. 4K decode plus a
3840x2400 display pipeline is several watts of that, and a PL1 tight enough to
look impressive is a PL1 that stutters video.

**The iGPU is the half people miss.** Measured here with a windowed 4K YouTube
playing, the integrated GPU sat at 1100-1200 MHz against a 350 MHz floor — to
*composite a desktop*, not to decode anything. i915's waitboost is why: a client
stalling on a buffer boosts the GPU to `gt_boost_freq_mhz`, which ships at RP0.
The governor caps both that and `gt_max_freq_mhz` on the lower tiers.

On AC it restores the firmware's own numbers and gets out of the way. It owns
exactly PL1, PL2, `max_perf_pct`, `no_turbo` and the iGPU clocks; EPP and the
platform profile stay with power-profiles-daemon, and the discrete GPU, Wi-Fi,
ASPM and runtime PM stay with the edge policy. One writer per register, enforced
by `/run/nova-powerd.owns-cpu`, which the bash half checks before touching
any of them.

### Fans

Off by default in the sense that matters: `FAN_CONTROL` defaults on but is
gated on `thinkpad_acpi` having been loaded with `fan_control=1`, which the
hardware profile writes to modprobe.d (`nova-hw-thinkpad-fan.conf`) and which
needs a reboot. Until then it is a
no-op with one line of explanation.

The battery curve is deliberately lazier than the EC's below 70 C, because a
warm chassis is cheaper than a spinning fan and the fan is most of a watt. Three
things stand between that and a hot machine, in order:

1. Above `GOVERNOR_TEMP_CRITICAL` the daemon hands the fans back to the EC
   *before* the curve is consulted, so no arrangement of curve entries can hold
   a low level on a hot package.
2. systemd's `ExecStopPost` runs `nova power daemon-stopped`, for the case
   where the daemon is killed outright and its own restore never runs.
3. The EC's own watchdog, refreshed every ten seconds or so, takes the fans back
   about thirty seconds after this process stops existing — needing nobody.

The level is re-asserted on every watchdog refresh rather than only on change,
because the EC silently takes the fans back across a resume and a cache would
never notice.

## Finding the rest of the watts

`sudo nova power doctor` reads the platform controller's latency-tolerance
table, the package C-state residency, whether the panel is self-refreshing,
and which PCI devices never sleep. The LTR table is the useful part: an IP
block advertising a short latency tolerance forbids the platform from entering
its deep package states, and the table names it.

On the P1 Gen 4i the answer was undramatic. xHCI advertises
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

## Browsing and video

Two of the levers are not the governor's at all, because they belong to the
compositor. Both are in Nova's `default/hypr/hardware/thinkpad-p1-gen4i.lua`.

**Direct scanout.** With it off — Hyprland's default — a fullscreen video is
composited into a fresh full-resolution buffer and blitted to the panel every
frame. On a 3840x2400 display that is the largest single thing the integrated
GPU does during playback, and none of it is necessary: the client's own buffer
can go straight to the display controller. `hyprctl monitors` says
`directScanoutBlockedBy: user settings` while it is off. `render:direct_scanout`
has to be `1`; `2` engages only for surfaces tagged `game`, and a video is
tagged `video`. The compositor falls back to compositing by itself the moment
something has to be drawn on top, so a notification or a screen recorder costs
correctness nothing.

**48 Hz.** The panel advertises one mode, `3840x2400@60`, but its EDID also
says `Display supports continuous frequencies` with ranges `48-60 Hz V,
148-148 kHz H`. The horizontal rate is pinned, so the way down is to keep the
592.56 MHz pixel clock and stretch vertical blanking — 3086 total lines instead
of 2469 — rather than slowing the clock, which would drop the horizontal rate
to 118 kHz and out of spec. That is 20% off every per-frame cost while anything
animates, and it puts 24 fps video in a clean 2:2 cadence; it also makes
scrolling visibly less smooth, which is why it is a key binding to try rather
than a default. A mode change is the one class of change here that can cost a
login, so nothing writes it to disk.

What was *already* right, so nobody re-tries it: hardware video decode. There
is no `vainfo` on this machine, so it was checked by calling `libva` directly —
`vaQueryConfigProfiles` on the iGPU's render node returns `VLD` decode for
H264, VP9 profiles 0-3, HEVC and `AV1Profile0`, and Chrome's GPU process has
`iHD_drv_video.so` mapped. YouTube's AV1 is being decoded in silicon; forcing
VP9 or h264ify would make things worse, not better.

The browser itself is still the largest term. Chrome's GPU process alone held
7.6% of a core continuously across six hours with 23 renderers open, before
anything was playing. `chrome://settings/performance` has Memory Saver and
Energy Saver, both at their defaults, and neither is something Nova can or
should set.

## Undervolting

The undervolt is `nova power undervolt`, below, and works only where the
firmware lets it. Undervolting an 11th-gen mobile part goes through the
overclocking mailbox at MSR `0x150`, gated after Plundervolt (CVE-2019-11157)
and locked by vendor firmware on business laptops. As shipped, a P1 Gen 4i
(i7-11850H, microcode `0x58`) takes a −5 mV offset to the CPU-core plane and
reads back **+0.0 mV**: the silent-ignore form of the lock. Its firmware's
hidden Advanced menu has the switch, **Overclocking Lock**; the way in, and
what an opened one took (−70 mV passed, −80 mV logged machine checks), are fact
16 in [thinkpad-p1-gen4i.md](hardware/thinkpad-p1-gen4i.md).

The AC/DC loadline trick, often suggested as a way around a locked undervolt,
is not one: it is a *different command to the same mailbox*, behind the same
lock.

Test it correctly — a zero-offset write that reads back zero proves nothing,
because a locked mailbox returns exactly that. Only a non-zero round trip
distinguishes "accepted" from "silently discarded", which is why
`nova-undervolt` reads every offset back.

With the lock open:

```sh
nova power undervolt set -70      # core and cache; asks for your password
nova power undervolt set -80 -70  # the core's, then the cache's
nova power undervolt              # what is set, and whether the CPU has it
sudo nova power undervolt         # plus the CPU's own registers
nova power undervolt compare -80 -70
nova power undervolt off
```

Settings → Performance has the same, with a slider each for the core and the
cache.

The core and the cache are thought to share one voltage on these CPUs, at the
higher of what the two offsets ask for: a core offset deeper than the cache's
may change nothing, and a core alone nothing at all. `compare` measures it on
yours: with the undervolt set now on, it runs one core flat out (every core,
with `--all`) and reads that core's voltage from IA32_PERF_STATUS (MSR
`0x198`), twenty times with the offset set now and twenty with the one given,
twice over in turns, compares the readings at the clock both have, and puts
the offset set now back. The machine-check watch is on throughout. The answer
holds for the load it ran: which of the two asks for more can change with the
clocks.

It is applied at boot and again after every sleep. The first machine check
takes it off, and so does the boot after one that ended without shutting
down while it was on; either way it stays off ("held", with the reason, in
Settings → Performance and `nova doctor`) until `nova power undervolt on`. Find
the depth with a stress test that checks its own arithmetic, and stay a step
short of the first machine check: a CPU that logs them is already wrong.

## What to expect

Numbers depend entirely on the machine, the panel and what is running, so
treat the following as one worked example rather than a promise. On the
ThinkPad P1 Gen 4i — RTX A2000, 3840x2400 panel — with the
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
knob here put together. `powertop` will tell you which of those applies to
yours; Nova deliberately does not guess.

Asleep, measured over a 63 minute suspend on the same machine:

| | |
|---|---|
| S3, awake-time subtracted | **1.26 W** |
| a full 74.5 Wh battery at that rate | ~59 h |
| hibernated | RTC only — days to weeks |

Which is the whole argument for suspend-then-hibernate: two hours of instant-wake S3
costs about 2.5 Wh, and everything after that costs nothing.

## Tests

```bash
src/power/test/roundtrip.sh
```

No root and no sysfs: it extracts the library half of the script,
points the tunables at temporary files and drives each battery -> AC round trip,
checking that the firmware's value is saved and restored and that a nonsense
wattage is refused rather than written to a register that governs package power.
A state file truncated on the way to battery, which leaves AC nothing to put
back, is the class of bug it catches.

It also covers the things that are not tunables but are just as easy to get
silently wrong:

- **`doctor`'s boot figures**, against fixture efivars — including a
  half-recorded pair, a garbage value and a backwards one. `doctor` runs as
  root, so a run by hand stops at its root guard: anything with `awk` in it is
  driven against real input here instead.
- **Wi-Fi power save**, against a stub `iw` that records its arguments. There
  is no file to inspect afterwards — the flag lives in the driver — and an
  inverted on/off mapping would look exactly like a working one.
- **The boost guard**, because the failure it prevents is a build losing its
  headroom on a resume with nothing said about it — and because the guard is
  the only reason a frequency ceiling is tolerable in the first place.
- **A RAPL state file written before PL2 existed**, which has two fields where
  the restore now reads three.
- **The handoff to the governor**, because two writers on one register is the
  easiest of these mistakes to make.

Every `/run` path the library consults is redirected into the fixture directory
first. On a machine running `nova-powerd`, the real `/run/nova-powerd.owns-cpu`
would otherwise have the library stand down from the registers a check asserts
on. A test that reads host state is not a test.

```bash
src/power/test/watts.sh [seconds]
```

Not a test: the measuring stick the numbers above come from. It needs a
battery and refuses to run on AC. It reports two figures — `energy_now`
differenced over the window, which is the honest one, and the mean of
`power_now`, which settles faster but is the firmware's estimate. Hold
everything else still between two runs; the panel backlight alone outweighs
every tunable here.
