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
| `~/.config/hypr/hyprland.lua` | `render:direct_scanout = 1` | a fullscreen video skips the composite pass entirely |
| `/etc/NetworkManager/conf.d/zz-thinkpad-power-wifi.conf` | `wifi.powersave = 1` | hands the flag to the policy, which sets it per power source |
| `/usr/local/bin/thinkpad-powerd` | the load-adaptive governor | CPU, iGPU and fans, continuously |
| `/etc/systemd/system/thinkpad-powerd.service` | runs it | `Restart=always`, with an `ExecStopPost` that puts everything back |
| `/etc/modprobe.d/thinkpad-power-fan.conf` | `thinkpad_acpi fan_control=1` | manual fan levels are refused without it |
| `~/.config/omarchy/extensions/omarchy-menu.jsonc` | overrides the GPU menu entry | live toggle instead of a reboot |
| `/etc/systemd/system/thinkpad-power-gpu.{service,timer}` | retry every 2 min | a plug event is one edge that never repeats |
| `/run/modprobe.d/thinkpad-power-nvidia.conf` | blocks the nvidia modules | while the card is off the bus, only then |
| supergfxd | disabled, package removed | it fights this and cannot switch reliably here |
| `/etc/mkinitcpio.conf.d/nvidia.conf` | **`--boot-path` only.** emptied, original kept alongside | the driver dragged 109 MB of GSP firmware into every initramfs |
| `systemd-tpm2-setup{,-early}` | **`--boot-path` only.** masked, and only with no LUKS and no pcrlock | 4.1 s per boot provisioning a key nothing reads |
| `/etc/systemd/sleep.conf.d/10-thinkpad-power.conf` | **`--hibernate` only.** `HibernateDelaySec`, `HibernateOnACPower=no` | S3 to RAM, then to disk, then no power |
| `/etc/systemd/logind.conf.d/10-thinkpad-power-lid.conf` | **`--hibernate` only.** lid and suspend key | the sleep nobody chooses explicitly |
| `/usr/lib/systemd/system-sleep/thinkpad-power-resume` | **`--hibernate` only.** rescans the bus after a hibernate | firmware re-enumerates the card; the restored image does not know |

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

Boot *colours* are deliberately not here — Limine and Plymouth drift from the
Omarchy theme, and fixing that is an Omarchy patch rather than power
management. It lives in `omarchy-boot-theme`.

Masking the TPM units takes a known 4.1 s off the userspace figure. What
emptying the initramfs is worth is **not yet measured** — the reasoning is that
the loader stage is dominated by reading a UKI carrying 109 MB of firmware it
never uses, but that is an inference from size, and only the next boot settles
it.

`sudo thinkpad-power doctor` prints the first two figures after each boot, so
the answer arrives on its own. They come from the loader's own
`LoaderTime*USec` efivars rather than `systemd-analyze`, whose split is skewed
here by a printk clock that starts at ~6.7 s.

## Installing

```
./install.sh                           the GPU and power policy
./install.sh --boot-path               also trim the initramfs and TPM units
./install.sh --hibernate               lid sleeps to RAM, then hibernates
./install.sh --hibernate-after=90min   the same, with a different delay
./install.sh --uninstall               put everything back
```

The two opt-in flags combine, and re-running is idempotent. Both are opt-in for
the same reason: everything in the base install is reversible from a running
session, and those two are not — one changes what boots, the other changes what
happens at power-on.

## Using it

```
thinkpad-power <command> [args]

  status [-v]         power source and discrete GPU; -v adds diagnostics
  doctor              what is keeping this machine awake (root)
  switch              turn the discrete GPU on or off, interactively
  run <cmd> [args]    run one program on the discrete GPU

  auto                apply the policy for the current power source
  post-hibernate      rescan the bus, then apply the policy (resume hook)
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

## Sleep

S3 on this machine costs **1.26 W**, measured over a 63 minute suspend. A full
74.5 Wh battery is therefore gone in about **59 hours**. A closed lid does not
survive a long weekend.

What a MacBook does is two things, not one: sleep to RAM, and then after a few
hours write RAM to disk and cut power entirely. systemd calls that
`suspend-then-hibernate`, and every prerequisite was already on this machine —
Omarchy's `omarchy-hibernation-setup` had laid down the swapfile, `resume=` and
`resume_offset` long ago. The only thing missing was anything asking for it.

```
./install.sh --hibernate                  RAM for 2 h, then disk
./install.sh --hibernate-after=90min      a different delay
```

| | |
|---|---|
| first 2 h | S3 at 1.26 W — instant wake, costs ~2.5 Wh |
| after that | hibernated: RTC only, days to weeks |
| on AC | plain suspend; `HibernateOnACPower=no`, against systemd's default of yes |

Opt-in, like `--boot-path`, and for a related reason: a hibernate that fails to
resume drops you at a fresh boot with the session gone. `--uninstall` puts the
lid back to plain suspend.

**Resuming from hibernate is a full power cycle, so it costs a whole boot** —
which is why the boot-path work comes first. It is also why the discrete card
needs handling: firmware enumerates it again on the way up, but the restored
image was taken with it off the bus, so the kernel has no record of it, never
touches it, and it sits in D0 drawing what this tool exists to save. Nothing
would report that — `thinkpad-power auto` sees no device and says "already off
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
device takes it is up to its driver, and a busy one will stay awake. Both are reverted on AC — the runtime PM changes are recorded
in `/run`, so only the devices this tool actually changed are put back, rather
than forcing the whole bus to `on` and overriding choices the drivers made at
boot.

The battery policy also turns **Wi-Fi power save on**, and back off on AC.
Omarchy disables it for the whole distribution, and its reasons are good ones:
20-300 ms latency spikes on an idle link, and Intel BE200/BE211 firmware that
drops the link outright when the radio naps. Neither applies on battery on the
machine this was written for — the radio is an AX210, which is not one of the
parts with that firmware bug, and a page load and a video stream both buffer
through the latency. The installer writes
`/etc/NetworkManager/conf.d/zz-thinkpad-power-wifi.conf` with
`wifi.powersave = 1` ("ignore"), because NetworkManager otherwise rewrites the
flag at every connection activation and a roam or a resume would quietly undo
it. Set `WIFI_POWERSAVE_ON_BAT=off` to disagree; `--uninstall` removes the file
and hands the flag back to Omarchy.

The remaining knobs are **opt-in**, in `/etc/thinkpad-power.conf`:

```sh
PL1_ON_BAT=30                # sustained CPU power limit on battery, in watts
PL2_ON_BAT=45                # burst limit; must be at least PL1_ON_BAT
CPU_MAX_PCT_ON_BAT=60        # frequency ceiling, percent of the P-state range
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
sudo thinkpad-power boost        # 30 minutes
sudo thinkpad-power boost 90     # or as long as the build takes
sudo thinkpad-power boost off    # early
```

It lifts both CPU caps for a bounded stretch and schedules its own expiry
through `systemd-run` before lifting anything, so a boost that fails to
schedule leaves the machine capped rather than uncapped forever. The marker
lives in `/run`, and both CPU tunables consult it, so a resume, a replug or the
retry timer cannot end a boost halfway through a build. `status -v` says when
one is active. The energy-performance preference and the platform profile are
*not* touched by any of this — those are power-profiles-daemon's, and two
things writing them means the last writer wins.

`ASPM_ON_BAT` is off by default because forcing L0s/L1 on every link can upset
a device that is merely ASPM-tolerant, and the symptom is a hang.
`NMI_WATCHDOG_ON_BAT` saves very little and costs you the hard-lockup
detector.

`thermald` is installed on this machine and deliberately not running. It drives
the same RAPL constraints this tool does, so leaving it off is what makes
`status -v` mean what it says.

## The governor

`thinkpad-powerd` is the continuous half, and it exists because RAPL gives you
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
by `/run/thinkpad-powerd.owns-cpu`, which the bash half checks before touching
any of them.

### Fans

Off by default in the sense that matters: `FAN_CONTROL` defaults on but is
gated on `thinkpad_acpi` having been loaded with `fan_control=1`, which the
installer writes to modprobe.d and which needs a reboot. Until then it is a
no-op with one line of explanation.

The battery curve is deliberately lazier than the EC's below 70 C, because a
warm chassis is cheaper than a spinning fan and the fan is most of a watt. Three
things stand between that and a hot machine, in order:

1. Above `GOVERNOR_TEMP_CRITICAL` the daemon hands the fans back to the EC
   *before* the curve is consulted, so no arrangement of curve entries can hold
   a low level on a hot package.
2. systemd's `ExecStopPost` runs `thinkpad-power daemon-stopped`, for the case
   where the daemon is killed outright and its own restore never runs.
3. The EC's own watchdog, refreshed every ten seconds or so, takes the fans back
   about thirty seconds after this process stops existing — needing nobody.

The level is re-asserted on every watchdog refresh rather than only on change,
because the EC silently takes the fans back across a resume and a cache would
never notice.

### Boost

`sudo thinkpad-power boost 90` pins the top tier for a bounded stretch. Both
halves read the same `/run/thinkpad-power.boost`, so it works whichever is
managing the CPU, and it survives a resume and a replug — a build must not lose
its headroom halfway through because the lid was closed.

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

### Browsing and video

Two of the levers here are not in this tool at all, because they belong to the
compositor. Both are in `~/.config/hypr/`.

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
Energy Saver, both at their defaults, and neither is something this tool can
or should set.

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

Asleep, measured over a 63 minute suspend on the same machine:

| | |
|---|---|
| S3, awake-time subtracted | **1.26 W** |
| a full 74.5 Wh battery at that rate | ~59 h |
| hibernated | RTC only — days to weeks |

Which is the whole argument for `--hibernate`: two hours of instant-wake S3
costs about 2.5 Wh, and everything after that costs nothing.

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

65 checks, no root and no sysfs: it extracts the library half of the script,
points the tunables at temporary files and drives each battery -> AC round trip,
checking that the firmware's value is saved and restored and that a nonsense
wattage is refused rather than written to a register that governs package power.
The runtime-PM state file was silently truncated on every battery run for a
while, so AC had nothing to put back; that is the class of bug this catches.

It also covers the things that are not tunables but are just as easy to get
silently wrong:

- **`doctor`'s boot figures**, against fixture efivars — including a
  half-recorded pair, a garbage value and a backwards one. An `awk` program in
  `doctor` once printed a label and no number for two commits because the only
  run during development hit the root guard, so anything with `awk` in it is
  driven against real input here.
- **The Omarchy menu override**, an `awk` program editing a JSONC file the
  compositor parses at startup. The result is parsed after both adding and
  removing the entry, because a malformed one costs the menu.
- **`--hibernate-after` parsing**, because a value that does not parse leaves a
  machine that suspends and never hibernates, which looks exactly like the
  feature silently not working.
- **Wi-Fi power save**, against a stub `iw` that records its arguments. There
  is no file to inspect afterwards — the flag lives in the driver — and an
  inverted on/off mapping would look exactly like a working one.
- **The boost guard**, because the failure it prevents is a build losing its
  headroom on a resume with nothing said about it — and because the guard is
  the only reason a frequency ceiling is tolerable in the first place.
- **A RAPL state file written before PL2 existed**, which has two fields where
  the restore now reads three.
- **The handoff to the governor**, because two writers on one register is the
  mistake this repository has already made once, with the power profiles.

Every `/run` path the library consults is redirected into the fixture directory
first. That is not tidiness: before it was done, installing `thinkpad-powerd`
made eight passing checks fail, because the real
`/run/thinkpad-powerd.owns-cpu` appeared and the library correctly stood down
from registers the test was about to assert on. A test that reads host state is
not a test.

```bash
./test/watts.sh [seconds]
```

Not a test: the measuring stick the numbers above come from. It needs a
battery and refuses to run on AC. It reports two figures — `energy_now`
differenced over the window, which is the honest one, and the mean of
`power_now`, which settles faster but is the firmware's estimate. Hold
everything else still between two runs; the panel backlight alone outweighs
every tunable in this repository.

## License

MIT — see [LICENSE](LICENSE).
