# Nova's power governor

`nova power` is one system with two halves. `nova-power` is the AC/battery
policy: the discrete GPU off the PCI bus on battery, CPU and platform
tunables, Wi-Fi power save, and the hibernate rescan. `nova-powerd` is the
load-adaptive governor that owns PL1, PL2, the frequency ceiling, the iGPU
ceiling and the fans while it runs.

Both ship in the `nova` package for every machine. Their tiers and limits are
measured on the ThinkPad P1 Gen 4i, so for now they start only there. What users need is
[docs/power.md](../../docs/power.md), and the commands, tunables and the governor are
under [Reference](#reference-moved-from-docspowermd) below;
how they are wired on the P1, and the facts behind every choice, are in
[docs/hardware/thinkpad-p1-gen4i.md](../../docs/hardware/thinkpad-p1-gen4i.md).

```
nova power                     what the governor is doing: power source, GPU, draw
nova power status -v           and the limits, the fans, runtime PM, ASPM, Wi-Fi
nova power gpu                 turn the discrete GPU on or off
nova power gpu mode off        keep it off plugged in too (Settings, Performance); auto undoes it
nova power gpu run <program>   one program on the discrete GPU
nova power undervolt           the CPU's voltage offset (any Intel laptop that allows one)
nova power lid lock            plugged in, a closed lid locks and the computer keeps running
nova power button sleep        the power button sleeps (or menu, the default, or off)
nova power hibernate 4h        asleep on battery, hibernate after four hours (or never)
sudo nova power doctor         what keeps the machine out of deep package states
sudo nova power boost 60       lift the battery CPU caps for an hour
```

| | |
|---|---|
| `bin/nova-power` | the policy |
| `daemon/` | the governor; std only, built by the workspace at the repository root |
| `systemd/`, `udev/` | units, the sleep hook and the plug rule, each DMI-guarded |
| `polkit/`, `bin/nova-power-gpu-mode-apply` | lets Settings choose the GPU mode without a password |
| `bin/nova-power-sleep-apply` | the root half of `nova power lid` and `hibernate`, through polkit too |
| `test/roundtrip.sh` | the policy's library half against fixtures; part of `make test` |
| `test/watts.sh` | the measuring stick: average draw on battery over N seconds |

## Reference (moved from docs/power.md)

<!-- RC15 docs rewrite: docs/power.md became a short user page. What follows
     is the old manual's reference for whoever works on the governor, moved
     here as it was; the numbered facts it cites are in
     docs/hardware/thinkpad-p1-gen4i.md. -->

### The command

```
usage: nova power [command] [args]

  status [-v]         power source and discrete GPU, the default; -v adds diagnostics
  status --json       the governor, limits, fans and draw, for Settings
  doctor              what is keeping this machine awake (root)
  switch              turn the discrete GPU on or off, interactively
  run <cmd> [args]    run one program on the discrete GPU
  prefer <cmd> [args] the same while the card is on the bus (plugged in);
                      else as it is, on the integrated GPU

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
  usb-added <dev>     on battery, let a USB device just plugged in autosuspend
                      (udev runs this)

  -h, --help          this message
```

- **Privileges:** `status`, `switch`, `run`, `prefer` and a bare `gpu-mode` need none; everything else requires root.
- **`status` is side-effect free.** In particular it does not call `nvidia-smi`, which would wake the card out of P8 just to answer.
- **`status` answers in three lines; `-v` adds the diagnostics.** Rows that have nothing to say are left out: `held by` appears only when something is actually holding the card, and `left on bus` only if a PCI function of it somehow survived being removed.
- **The policy is applied** on plug and unplug, at boot and after resume. A card it could not move (held by a program, or not back on a rescan) is tried again two minutes later, and again until it goes; so is the GPU once more after each plug, boot and resume, for a plug event lost in the run before. Nothing runs on a clock when the card is where it should be.

```
$ nova power status

  power source   battery (balanced)
  discrete GPU   off
  draw           12.94 W

$ nova power status -v

  power source   battery (balanced)
  discrete GPU   off
  draw           12.94 W

  address        0000:01:00.0
  functions      none on the bus
  driver load    blocked
  governor       battery/light, 4% busy, 52 C, fans 0, 9.8 W
  runtime pm     8 devices set to auto
  usb pm         3 devices set to auto
  wifi ps        wlp9s0 on
  pcie aspm      the firmware's
  cpu pl1        12 W over 10s
  cpu pl2        18 W burst
  cpu ceiling    45% no turbo (2.2 GHz)
```

### Wake

**Wake on this machine is not slow where it looks slow.** Low-level resume to `PM: suspend exit` is **188 ms**, and the lock screen is prompting **1.04 s** after that. What is felt as five seconds is the fingerprint reader, and two separate things happen to it across S3.

**It loses power and re-enumerates.** The lock screen starts its PAM fingerprint session before that finishes and gets `device was disconnected`, so it retries: four times in 900 ms here before the fourth caught a live device.

Marking the reader wake-capable, so its port stays powered, was tried and is **ruled out**:

- It works, in the narrow sense: the retries dropped from 4 to 1.
- It also left the reader in a state fprintd refuses (`Ignoring device due to initialization error: unsupported firmware version`), so fingerprint unlock did not work at all on resume.
- Trading a working unlock for 0.9 s is not a trade worth making, so there is no knob for it.

**It fails to match.** This is the larger half, and no kernel knob touches it. Enrolling one finger means a slightly-off placement fails: the measured resume above spent 4.7 s waiting for a finger and then failed twice before the third attempt authenticated, at 8.0 s. More enrolled fingers is the fix:

```
fprintd-enroll -f left-index-finger
fprintd-enroll -f right-thumb
```

Two other devices resume badly and are worth knowing about, though neither gates the unlock:

- the 5G modem fails with `-22` and does a full recovery cycle;
- the Thunderbolt xHCI controller reinitialises, which makes usb1 and usb2 report `root hub lost power or was reset`.

### Tunables

#### What the battery policy sets by itself

**Runtime power management and the HDA codec.** Beyond the GPU, the battery policy sets runtime power management to `auto` on PCI devices whose drivers left them pinned at `on`, and lets the HDA codec sleep between sounds.

- `auto` grants permission to suspend; whether a device takes it is up to its driver, and a busy one will stay awake.
- Both are reverted on AC. The runtime PM changes are recorded in `/run`, so only the devices the policy actually changed are put back, rather than forcing the whole bus to `on` and overriding choices the drivers made at boot.

**Wi-Fi power save is on, on battery,** and back off on AC.

- Some distributions turn it off for every machine, and their reasons are good ones: 20-300 ms latency spikes on an idle link, and Intel BE200/BE211 firmware that drops the link outright when the radio naps.
- Neither applies on battery on the P1 Gen 4i. The radio is an AX210, which is not one of the parts with that firmware bug, and a page load and a video stream both buffer through the latency.
- The hardware profile installs `/etc/NetworkManager/conf.d/nova-hw-wifi-powersave.conf` with `wifi.powersave = 1` ("ignore"), because NetworkManager otherwise rewrites the flag at every connection activation, and a roam or a resume would quietly undo it.
- Set `WIFI_POWERSAVE_ON_BAT=off` to disagree.

#### The opt-in knobs

The remaining knobs are **opt-in**, in `/etc/nova/power.conf`. `PL1_ON_BAT`, `PL2_ON_BAT` and `CPU_MAX_PCT_ON_BAT` do nothing while `nova-powerd` runs, which is the default: its tiers set those registers.

```sh
PL1_ON_BAT=30                # sustained CPU power limit on battery, in watts
PL2_ON_BAT=45                # burst limit; must be at least PL1_ON_BAT
CPU_MAX_PCT_ON_BAT=60        # frequency ceiling, percent of the top turbo clock
ASPM_ON_BAT=powersave        # or powersupersave, which adds the L1 substates
NMI_WATCHDOG_ON_BAT=off      # disable the lockup detector on battery
```

**`PL1_ON_BAT` is the one that changes anything under load.** Firmware here leaves the sustained limit at the AC figure on battery (109 W on the P1 Gen 4i, against a 45 W part), so a busy browser is free to empty the battery as fast as the cooling allows. Capping it is safe in the way undervolting is not: the worst case is a slower CPU, not an unstable one.

PL1 is an *average over a time window*, and the firmware sets that window to 56 seconds, so a burst lasting most of a minute escapes the cap entirely. Setting `PL1_ON_BAT` therefore also shortens the window to 10 s; both values are restored on AC. Check `nova power status -v` afterwards: it prints the limit and the window, and DPTF drives the same registers, so it is worth confirming rather than assuming.

**`PL2_ON_BAT` is the one you feel rather than measure.** PL2 governs the burst before PL1's average catches up: 135 W here against a 45 W part, over a 2.44 ms window, so every page render is allowed a spike at three times TDP.

- The energy in one burst is small; the heat is not, and it is where the fan noise and the warm palm rest come from.
- Capping it makes the machine run cool rather than merely last longer.
- It must be at least `PL1_ON_BAT`. A burst limit below the sustained limit is a contradiction, and it is refused rather than written.

**`CPU_MAX_PCT_ON_BAT` is the answer to "why is it hot when I am only reading a web page".** Under HWP, `intel_pstate` will still walk to the top of the range to scroll, and the last third of the frequency range costs disproportionately more power than it returns in speed.

- This part reaches 4.8 GHz on a 2.5 GHz base clock, so a ceiling below about 52 takes turbo off the table entirely.
- It is a ceiling, not a target: nothing is slower until something actually asks for more than the ceiling.

**`ASPM_ON_BAT` is off by default**, because forcing L0s/L1 on every link can upset a device that is merely ASPM-tolerant, and the symptom is a hang. On the P1 Gen 4i it does nothing at all: the firmware keeps ASPM to itself (the kernel logs "FADT indicates ASPM is unsupported"), and `nova power status` shows the policy as the firmware's.

**`NMI_WATCHDOG_ON_BAT`** saves very little and costs you the hard-lockup detector.

#### Boost, for a compile

What *does* ask for the whole CPU is a compile, which is what `boost` is for:

```sh
sudo nova power boost        # 30 minutes
sudo nova power boost 90     # or as long as the build takes
sudo nova power boost off    # early
```

- It lifts both CPU caps for a bounded stretch (the governor's top tier, while it runs).
- It schedules its own expiry through `systemd-run` before lifting anything, so a boost that fails to schedule leaves the machine capped rather than uncapped forever.
- The marker, `/run/nova-power.boost`, is read by both halves, so it works whichever is managing the CPU, and a resume, a replug or the retry timer cannot end a boost halfway through a build.
- `status -v` says when one is active.

The energy-performance preference and the platform profile are *not* touched by any of this. Those are power-profiles-daemon's, and two things writing them means the last writer wins.

#### thermald

`thermald` is installed on this machine and deliberately not running. It drives the same RAPL constraints the governor does, so leaving it off is what makes `status -v` mean what it says.

### The governor

**`nova-powerd` is the continuous half, and it exists because RAPL gives you the opposite of what a laptop wants.**

- PL1/PL2 is *high briefly, low sustained*: a burst gets 135 W and a long job gets throttled.
- What is wanted is *low briefly, high sustained*: a browser must never reach 4.8 GHz to scroll a page, and a compile must have everything.
- No register does that, because it is a policy about time, and a policy about time needs something awake to watch the clock.

#### The ladder

Four tiers on battery, and a ladder that gets harder to climb:

| tier | PL1 | PL2 | ceiling | iGPU | reached after |
|---|---|---|---|---|---|
| `light` | 12 W | 18 W | 45%, turbo off | 800 MHz | the default |
| `mid` | 18 W | 28 W | 70% | 1050 MHz | 8 s of load |
| `full` | 28 W | 42 W | 100% | free | 16 s more |
| `turbo` | 40 W | 60 W | 100% | free | 24 s more |

**The dwell is the whole design.**

- Climbing needs sustained load, longer at every rung, so about a minute of unbroken work to reach the top, which nothing but a real job produces.
- Falling needs 25 s of quiet, so the gaps between files in a build do not cost a re-ramp.
- Between the two thresholds nothing moves at all, which is what stops a load hovering on the line from oscillating.
- `iowait` is not counted as busy: a build waiting on the NVMe is not asking for frequency.

#### The battery's mode

**The battery's mode decides how much of the ladder there is.** The governor reads it from the platform profile power-profiles-daemon sets (the CPU's energy preference where there is none):

| mode | tiers | climbing |
|---|---|---|
| saver | `light` only | never: battery first, and `nova power boost` for the job that needs more |
| balanced | `light` to `turbo` | as above, about a minute to the top |
| performance | `mid` to `turbo` | four times as fast: 4 s to `full`, then 6 s more to `turbo` |

- **Saver is where every unplug starts**, and where a restart on battery starts too: a mode chosen on battery lasts until the next plug-in. A performance chosen for one job and then forgotten stayed for a day and a half, and drew about 30 W through a YouTube video (fact 52 in the P1 Gen 4i notes).
- **A change of mode** starts the ladder again at the new mode's bottom, as an unplug does.
- **A boost outranks the mode, and temperature outranks both:** a package past 85 °C steps down a tier, below the mode's floor too.

#### Why the ceiling, and why the iGPU

**The ceiling is the lever; PL1 is the safety net.** Power goes roughly as *f·V²* and V tracks f, so the top of the frequency curve costs several times what it returns. 45% of 4.8 GHz is about 2.16 GHz, under the 2.5 GHz base ratio, so turbo is unreachable before `no_turbo` even says so.

PL1 is not set lower on purpose. `intel-rapl:0` is the **package** domain, with `core` and `uncore` beneath it, so the iGPU spends from the same budget. 4K decode plus a 3840x2400 display pipeline is several watts of that, and a PL1 tight enough to look impressive is a PL1 that stutters video.

**The iGPU is the half people miss.** Measured here with a windowed 4K YouTube playing, the integrated GPU sat at 1100-1200 MHz against a 350 MHz floor, to *composite a desktop*, not to decode anything. i915's waitboost is why: a client stalling on a buffer boosts the GPU to `gt_boost_freq_mhz`, which ships at RP0. The governor caps both that and `gt_max_freq_mhz` on the lower tiers.

#### Plugged in

**Plugged in there is one mode: everything**, turbo and the whole frequency range, to Nova's own limits of 109 W sustained and 135 W in bursts, held in both copies of PL1 (fact 50 in the P1 Gen 4i notes).

They are the firmware's own figures, and nothing lower would help: under a long load the package reaches its 96 °C at 50-60 W, so its heat is the limit plugged in, and the fans are what is worth having more of.

#### One writer per register

The governor owns exactly PL1, PL2, `max_perf_pct`, `no_turbo`, the iGPU clocks and the fans.

- EPP and the platform profile stay with power-profiles-daemon.
- The discrete GPU, Wi-Fi, ASPM and runtime PM stay with the edge policy.
- One writer per register is enforced by `/run/nova-powerd.owns-cpu`, which the bash half checks before touching any of them.

#### Fans

**Off by default in the sense that matters.** `FAN_CONTROL` defaults on, but is gated on `thinkpad_acpi` having been loaded with `fan_control=1`, which the hardware profile writes to modprobe.d (`nova-hw-thinkpad-fan.conf`) and which needs a reboot. Until then it is a no-op with one line of explanation.

**The fans follow Nova's own curves, not the EC's.** The EC's stops at about 3,600-4,000 rpm with the package held at its 96 °C, short of what the fans can do, and spins them at about 2,500 rpm on an idle desktop plugged in.

Two curves, a level (0 to 7, then full speed) from the temperature it starts at:

| | still to | 1 | 2 | 3 | 4 | 5 | 7 | full speed |
|---|---|---|---|---|---|---|---|---|
| plugged in | 55 °C | 55 | 62 | 68 | 74 | 79 | 84 | 88 |
| on battery | 70 °C | 70 | 78 | | 84 | | 88 | 92 |

- **Plugged in** there is no battery to spare, and any load that lasts reaches full speed.
- **On battery** a warm chassis is cheaper than a spinning fan, which is most of a watt, and the tiers keep the package cooler anyway.

**The temperature** is the hottest of the package and the EC's own sensors: the board, and the discrete GPU while it is awake. The EC reads the card without waking it, and has nothing for it while it sleeps, when it makes no heat.

- The curve reads an average of the last few seconds, the time the heatsink takes to follow, so the fans rise as heat builds and not at each one-second spike.
- They come down a level at a time, once 3 °C below where the level starts for 12 s, so a build's pauses do not set them hunting.

Four things stand between that and a hot machine, in order:

1. Anything at `GOVERNOR_TEMP_CRITICAL` (92 °C) for three polls, the package or the GPU, has full speed at once, whatever the curve says.
2. With no package temperature to go by, the fans go back to the EC.
3. systemd's `ExecStopPost` runs `nova power daemon-stopped`, for the case where the daemon is killed outright and its own restore never runs.
4. The EC's own watchdog, refreshed every ten seconds or so, takes the fans back about thirty seconds after this process stops existing, needing nobody.

The level is re-asserted on every watchdog refresh rather than only on change, because the EC silently takes the fans back across a resume and a cache would never notice.

### Finding the rest of the watts

**`sudo nova power doctor` names what keeps the platform out of its deepest idle.** It reads the platform controller's latency-tolerance table, the package C-state residency, whether the panel is self-refreshing, and which PCI devices never sleep.

The LTR table is the useful part: an IP block advertising a short latency tolerance forbids the platform from entering its deep package states, and the table names it.

**On the P1 Gen 4i the table pointed at the right device for the wrong reason.**

1. xHCI advertises 500 µs, and the first reading of that was "the Bluetooth mouse, in use, nothing to do".
2. But ignoring the LTR changes nothing: the package still never reaches PC10.
3. What blocks it is the USB controller never sleeping, because two devices on it were pinned awake and polled every millisecond: the Bluetooth controller (autosuspend off in the hardware profile, for mouse lag) and a mouse receiver (the kernel's default for HID).
4. Let both autosuspend and the controller sleeps: PC10 goes from 0% to about 70%, and the idle desktop drops from 10.7 W to 8.5 W.
5. On battery `nova-power` now does that for every USB device the kernel left awake, with a 10 s delay for input devices, and leaves audio devices alone. It puts them back on AC.

Panel Self Refresh was already enabled (PSR1; the panel does not support PSR2 or Panel Replay, so there is nothing further to switch on). Hardware video decode was already working.

That is the usual shape of this exercise:

1. the large win is the discrete GPU;
2. the second is the power limit under load;
3. after that, whichever single device keeps the platform out of its deepest idle state.

The table names a suspect; `ltr_ignore` and the package C-state counters say whether it is really the culprit.

### Browsing and video

Two of the levers are not the governor's at all, because they belong to the compositor. The first is in Nova's `default/hypr/hardware/thinkpad-p1-gen4i.lua`.

#### Direct scanout

**With it off (Hyprland's default), a fullscreen video is composited into a fresh full-resolution buffer and blitted to the panel every frame.** On a 3840x2400 display that is the largest single thing the integrated GPU does during playback, and none of it is necessary: the client's own buffer can go straight to the display controller.

- `hyprctl monitors` says `directScanoutBlockedBy: user settings` while it is off.
- `render:direct_scanout` has to be `1`; `2` engages only for surfaces tagged `game`, and a video is tagged `video`.
- The compositor falls back to compositing by itself the moment something has to be drawn on top, so a notification or a screen recorder costs correctness nothing.

#### 48 Hz

**The panel can run at 48 Hz, by stretching vertical blanking; Nova does not ship it.**

- The panel advertises one mode, `3840x2400@60`, but its EDID also says `Display supports continuous frequencies` with ranges `48-60 Hz V, 148-148 kHz H`.
- The horizontal rate is pinned, so the way down is to keep the 592.56 MHz pixel clock and stretch vertical blanking (3086 total lines instead of 2469), rather than slowing the clock, which would drop the horizontal rate to 118 kHz and out of spec.
- That is 20% off every per-frame cost while anything animates, and it puts 24 fps video in a clean 2:2 cadence.
- It also makes scrolling visibly less smooth, and a mode change is the one class of change here that can cost a login, so Nova sets nothing.

#### What was already right

What was *already* right, so nobody re-tries it: **hardware video decode.** There is no `vainfo` on this machine, so it was checked by calling `libva` directly: `vaQueryConfigProfiles` on the iGPU's render node returns `VLD` decode for H264, VP9 profiles 0-3, HEVC and `AV1Profile0`, and Chrome's GPU process has `iHD_drv_video.so` mapped. YouTube's AV1 is being decoded in silicon; forcing VP9 or h264ify would make things worse, not better.

#### What a page costs

**The browser itself is still the largest term.** Chrome's GPU process alone held 7.6% of a core continuously across six hours with 23 renderers open, before anything was playing.

**What a page costs is mostly whether anything on it moves.** The panel does PSR1, self-refresh of the whole frame or nothing, so a single animated pixel takes it out of self-refresh, and the display engine reads the full 3840x2400 frame from memory sixty times a second.

Measured on 2026-11-10, battery, power-saver, backlight 180/600, PC10 working (fact 54):

| | battery |
|---|---|
| idle desktop | 7.7-8.5 W |
| Chrome, a page of text | 8.7 W |
| the same page with one 48 px spinner | 13.4 W |
| the spinner, Energy Saver on (30 fps) | 12.7 W |
| video, 2160p30 AV1, fullscreen | 15.0 W |
| video, 1080p60 or 2160p60 AV1 | 17.0-17.7 W |

**Frame rate costs more than resolution:** 1080p60 draws more than 2160p30, because each frame is composited twice at panel resolution, once by Chrome and once by the compositor.

Tried during playback and worth nothing measurable:

- direct scanout itself (mpv at scale 1, the only way past the opaque check: 17.6 W with it, 17.9 W without);
- Chrome's `WaylandOverlayDelegation` (it does clear Hyprland's `SURFACES` blocker);
- the iGPU cap at 500, 600 or 1100 MHz instead of 800 (lower drops frames and keeps the package awake longer);
- the uncore capped at 2.0 or 1.4 GHz.

So patching Hyprland's opaque check for scaled outputs is not worth carrying.

#### Chrome's Energy Saver

**Chrome's Energy Saver does work on Linux, and Nova turns it on.** "Turn on when the computer is unplugged" (`performance_tuning.battery_saver_mode.state = 2` in Local State) sees the battery with no flag at all:

- started on battery, a page's `requestAnimationFrame` runs at 30 instead of 60, and plugged in at 60;
- it follows the power source while Chrome runs: unplugged at 21:38:27, the page was at 30 within ten seconds, with no restart;
- video is untouched.

Chrome hides the section in its settings on Linux all the same, because it does not think the computer has a battery, so the setting has to be written into Local State. Nova turns it on once per profile at login (`nova-chrome-energy-saver`), while Chrome cannot yet be open to write its own copy back. After that it is Chrome's setting.

### Undervolting

**The undervolt is `nova power undervolt`, and works only where the firmware lets it.**

Undervolting an 11th-gen mobile part goes through the overclocking mailbox at MSR `0x150`, gated after Plundervolt (CVE-2019-11157) and locked by vendor firmware on business laptops. As shipped, a P1 Gen 4i (i7-11850H, microcode `0x58`) takes a −5 mV offset to the CPU-core plane and reads back **+0.0 mV**: the silent-ignore form of the lock.

Its firmware's hidden Advanced menu has the switch, **Overclocking Lock**. The way in, and what an opened one took (−70 mV passed, −80 mV logged machine checks), are fact 16 in [thinkpad-p1-gen4i.md](../../docs/hardware/thinkpad-p1-gen4i.md).

- **The AC/DC loadline trick**, often suggested as a way around a locked undervolt, is not one: it is a *different command to the same mailbox*, behind the same lock.
- **Test it correctly.** A zero-offset write that reads back zero proves nothing, because a locked mailbox returns exactly that. Only a non-zero round trip distinguishes "accepted" from "silently discarded", which is why `nova-undervolt` reads every offset back.

With the lock open:

```sh
nova power undervolt set -70      # core and cache; asks for your password
nova power undervolt set -80 -70  # the core's, then the cache's
nova power undervolt              # what is set, and whether the CPU has it
sudo nova power undervolt         # plus the CPU's own registers
nova power undervolt compare -80 -70
nova power undervolt off
```

Settings → Performance has the same, with a slider each for the core and the cache.

#### Core and cache

**On some of these CPUs the core and the cache share one voltage**, at the higher of what the two offsets ask for: a core offset deeper than the cache's changes nothing there, and a core alone nothing at all. On the P1 Gen 4i the core's is its own: at 4.4 GHz, -80 mV on the core with -70 on the cache ran 10 mV below -70 on both.

`compare` measures it on yours, with the undervolt set now on:

1. it runs one core flat out (every core, with `--all`);
2. it reads that core's voltage from IA32_PERF_STATUS (MSR `0x198`), twenty times with the offset set now and twenty with the one given, twice over in turns;
3. it compares the readings at the clock both have;
4. it puts the offset set now back.

The machine-check watch is on throughout. The answer holds for the load it ran: which of the two asks for more can change with the clocks.

#### When it is applied, and held

- It is applied at boot and again after every sleep.
- The first machine check takes it off, and so does the boot after one that ended without shutting down while it was on.
- Either way it stays off ("held", with the reason, in Settings → Performance and `nova doctor`) until `nova power undervolt on`.

Find the depth with a stress test that checks its own arithmetic, and stay a step short of the first machine check: a CPU that logs them is already wrong.

### What to expect

**Numbers depend entirely on the machine, the panel and what is running**, so treat the following as one worked example rather than a promise. On the ThinkPad P1 Gen 4i (RTX A2000, 3840x2400 panel), with the screen at 30% and a light desktop:

| | draw |
|---|---|
| discrete GPU bound and idle | ~26 W |
| discrete GPU off the bus | ~20 W |

- The card is worth about 6 W of that, which on that 74.5 Wh battery is roughly the difference between 2.3 and 3.0 hours.
- The tunables are worth a fraction of a watt between them.

They are also not where the remaining watts are. On that machine the panel and the browser dominate, and a connected 5G modem costs more than every kernel knob here put together. `powertop` will tell you which of those applies to yours; Nova deliberately does not guess.

Asleep, on the same machine, see the sleep facts in [the P1's notes](../../docs/hardware/thinkpad-p1-gen4i.md): S3 at 1.26 W with the awake time subtracted, about 59 hours for a full 74.5 Wh battery, and RTC only once hibernated, which is the whole argument for suspend-then-hibernate.

### Tests

```bash
src/power/test/roundtrip.sh
```

**No root and no sysfs.** It extracts the library half of the script, points the tunables at temporary files and drives each battery -> AC round trip. It checks that the firmware's value is saved and restored, and that a nonsense wattage is refused rather than written to a register that governs package power. A state file truncated on the way to battery, which leaves AC nothing to put back, is the class of bug it catches.

It also covers the things that are not tunables but go wrong as silently:

- **`doctor`'s boot figures**, against fixture efivars, including a half-recorded pair, a garbage value and a backwards one. `doctor` runs as root, so a run by hand stops at its root guard: anything with `awk` in it is driven against real input here instead.
- **Wi-Fi power save**, against a stub `iw` that records its arguments. There is no file to inspect afterwards (the flag lives in the driver), and an inverted on/off mapping would look exactly like a working one.
- **The boost guard**, because the failure it prevents is a build losing its headroom on a resume with nothing said about it, and because the guard is the only reason a frequency ceiling is tolerable in the first place.
- **A RAPL state file written before PL2 existed**, which has two fields where the restore now reads three.
- **The handoff to the governor**, because two writers on one register is the easiest of these mistakes to make.

Every `/run` path the library consults is redirected into the fixture directory first. On a machine running `nova-powerd`, the real `/run/nova-powerd.owns-cpu` would otherwise have the library stand down from the registers a check asserts on. A test that reads host state is not a test.

```bash
src/power/test/watts.sh [seconds]
```

**Not a test: the measuring stick the numbers above come from.** It needs a battery and refuses to run on AC. It reports two figures:

- `energy_now` differenced over the window, which is the honest one;
- the mean of `power_now`, which settles faster but is the firmware's estimate.

Hold everything else still between two runs; the panel backlight alone outweighs every tunable here.
