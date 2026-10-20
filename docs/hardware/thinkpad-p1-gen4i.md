# ThinkPad P1 Gen 4i

Power management for the P1 Gen 4i: `thinkpad-power` (the policy, bash) and
`thinkpad-powerd` (the load-adaptive governor, Rust), in `src/power/`. Read
this before changing anything there: most of it was learned the expensive way,
twice at the cost of a login screen.

## How Nova wires it

Everything ships in the `nova` package and is inert on any other computer.

| | |
|---|---|
| `/usr/lib/nova/bin/thinkpad-power`, `thinkpad-powerd` | the policy and the governor |
| `thinkpad-power.service`, `thinkpad-powerd.service`, `thinkpad-power-gpu.timer` | enabled by the package, each with `ConditionFirmware=smbios-field(product_version $= "ThinkPad P1 Gen 4i")` |
| `99-nova-thinkpad-power.rules` | plug and unplug re-apply the policy (DMI-matched) |
| `98-nova-igpu.rules` | `/dev/dri/igpu`, the colon-free name for the integrated card (fact 1) |
| `/usr/lib/systemd/system-sleep/thinkpad-power-resume` | the hibernate rescan (fact 29) |
| `/usr/share/uwsm/env.d/20-nova-thinkpad-p1-gen4i` | the compositor pin and the hidden NVIDIA EGL vendor and Vulkan ICD (facts 1-3) |
| `default/hypr/hardware/thinkpad-p1-gen4i.lua` | VA-API and GLX on the iGPU, direct scanout (fact 31) |
| `data/hardware/thinkpad-p1-gen4i/etc/` | fan control, `nvidia-drm fbdev=0`, Bluetooth autosuspend off, NetworkManager's hands off the Wi-Fi power-save flag, and `rtc_cmos.use_acpi_alarm=1`; copied into `/etc` by `nova-hw-apply` from a pacman hook |
| `/usr/lib/systemd/{logind,sleep}.conf.d/10-nova.conf` | suspend-then-hibernate on the lid, never hibernating on AC (facts 26, 30, 38), for every Nova machine |
| `nova-power-profile` | power profiles, remembered per power source (fact 4); power-saver on battery by default |
| `nova power gpu` | the switch, `status` and `run` |

`/etc/thinkpad-power.conf` is optional and holds the tunables below
(`PL1_ON_BAT`, the governor's tiers, `FAN_CONTROL`, ...). The dGPU's address
is found at boot, when firmware has always enumerated it, and kept in
`/run/thinkpad-power.nvidia-pci` for the rest of the boot (fact 15).

The numbered facts below were learned before Nova existed, when this was an
add-on with an installer of its own. Where Nova now does something differently,
the fact says how; the hardware findings and the measurements stand as they
were.

## The machine

ThinkPad P1 Gen 4i, i7-11850H. The facts below were measured on Hyprland 0.56
and aquamarine 0.14, under uwsm.

| | |
|---|---|
| iGPU | `0000:00:02.0`, i915 — **drives eDP-1 and every connected output** |
| dGPU | `0000:01:00.0`, RTX A2000 Mobile, nvidia 610.57.04 |
| dGPU outputs | DP-1, DP-2, HDMI-A-1 — **none connected** while measuring |
| Idle cost of the dGPU | ~6.2 W at P8 while merely bound; battery is 74.5 Wh of 90 Wh design |

Because the panel is on the iGPU, the discrete card renders nothing on the
desktop and can be removed from the PCI bus outright. That is the whole idea.

## Hard-won facts

**1. `AQ_DRM_DEVICES` must not contain a colon.** It is a `:`-separated list,
so `/dev/dri/by-path/pci-0000:00:02.0-card` is torn into three nonexistent
paths; aquamarine matches none, logs *"Found no gpus to use"*, and throws
`CBackend::create() failed!`. The session dies and the greeter silently clears
the password field. Hence the `/dev/dri/igpu` udev symlink
(`98-nova-igpu.rules`), which is also stable across boots where
`cardN` numbering is not.

**2. Pinning the DRM device is not enough.** It decides which card *draws*, not
which driver the graphics libraries *load*. GLVND loads every EGL vendor it
finds (`10_nvidia.json` sorts before `50_mesa.json`), so `libEGL_nvidia` lands
inside Hyprland; the Vulkan loader loads every ICD, so any GTK4 app (GTK4
renders with Vulkan) opens `/dev/nvidia0`, `/dev/nvidiactl` and
`/dev/nvidia-modeset` just by starting. Measured: 9 NVIDIA libraries and three
device nodes on a bare `vkCreateInstance`; zero once filtered. Hence
`__EGL_VENDOR_LIBRARY_FILENAMES` and `VK_LOADER_DRIVERS_DISABLE=*nvidia*` in
`/usr/share/uwsm/env.d/20-nova-thinkpad-p1-gen4i`.

**3. uwsm sources that file with `/bin/sh`** (`/usr/lib/uwsm/prepare-env.sh`,
`. "${1}"`), for every session on every machine. A file that does not parse
costs the login. The add-on generated it at install time, and once left a
dangling `if` with its `fi` deleted. Nova's is a fixed file in the package: it
reads the model before doing anything else, runs no programs, and the unit
tests parse it and source it under `sh`. Keep it POSIX.

**4. Power profiles have one owner, and it is not this tool.** Before Nova, the
desktop remembered a profile per power source and set it on every plug event,
and this tool set profiles too; the last writer won, and the profiles were
lost. Now `nova-power-profile` remembers one per source in
`~/.local/state/nova/power-profile/`, and the shell's battery service puts it
back at login and on every plug and unplug. **thinkpad-power never sets a
profile**, and leaves EPP and the platform profile to power-profiles-daemon.

**5. Do not order the unit `After=power-profiles-daemon.service`.** PPD is
itself `After=multi-user.target`, so it closes a cycle and systemd breaks it by
*deleting PPD's start job* — PPD then does not start at boot.

**6. supergfxctl is left out on purpose.** Reboot per switch, `hotplug_type: None`
on non-ASUS hardware, and its `Integrated` leftovers
(`/usr/lib/systemd/system-sleep/force-igpu`, `supergfxd.service.d/delay-start.conf`)
run `supergfxctl -m Vfio/-m Integrated` on **every resume**. The switch is
`nova power gpu`, which is also the menu's Discrete GPU entry. That entry is
shown by the model (`nova-hw-detect`), not by counting GPUs: a count with
`lspci` would hide it exactly when the card is off, and wakes the card to ask.

**7. The policy is edge-triggered and can legitimately decline.** `gpu_off`
refuses while anything holds the card, rather than pulling it from under a
running program. A plug event is one edge that never repeats, so
`thinkpad-power-gpu.timer` retries every 2 min, GPU only, never touching the
profile.

**8. Use `thinkpad-power run`, not `prime-run`.** The session hides the NVIDIA
EGL vendor and Vulkan ICD; `prime-run` does not know to restore them. Steam
launch options: `thinkpad-power run %command%`.

**9. The card is more than one PCI function.** `0000:01:00.0` is the GPU;
`0000:01:00.1` is its HDA controller for HDMI/DP audio, bound to
`snd_hda_intel` and registered as ALSA `card0`. `echo 1 > .../remove` takes
**one function**. Removing only the GPU left the audio controller on a bus
that was losing power: its registers read back `0xffffffff` and the next
access killed the machine with *"Timeout: Not all CPUs entered broadcast
exception handler"* — `mce_timed_out()`, a broadcast machine check, not
anything a compositor can survive. On battery `extras` sets `snd_hda_intel
power_save=1`, so that driver suspends and resumes the controller on its own
schedule and the freeze arrived with nobody touching the machine. Remove
**every** function, highest first, so function 0 — and with it the card's
power — goes last.

**10. `nvidia-modprobe` is setuid root and will undo the unload.** Any process
that opens a `/dev/nvidia*` node gets the module back, and those nodes outlive
the unload. `btop` does it every couple of seconds through NVML. Loading the
driver while the card is off the bus reaches the same machine check: card
removed 11:09:05, `nvidia` loaded 11:09:18, panic 11:09:42. `gpu_off` now
writes `install <module> /bin/false` into
`/run/modprobe.d/thinkpad-power-nvidia.conf` **before** unloading — the gap
between unload and block is enough on its own — and deletes the nodes once the
functions are gone. `gpu_on` lifts the block **before** the rescan, since the
rescan is itself what makes udev try the driver. `/run` is a tmpfs, so a block
can never survive into a boot where the card is back.

**11. `run` had no `die`.** It was called twice and never defined, and there is
no `set -e`, so `thinkpad-power run` on battery printed `die: command not
found` and then `exec`ed the program anyway with the NVIDIA EGL vendor and
Vulkan ICD restored — a third route to fact 10's panic. Defined now.

**12. Two units can run at once, and the loser must not clean up.** The udev
plug rule and the 2 min retry timer both fire `gpu_off`. At 11:35:09 the udev
run removed the card and installed the modprobe block; the timer, 81 ms
behind, found the functions already gone, called its failure path, and
*deleted the block the winner had just installed* — card off the bus, driver
free to load. Three guards now: `flock` on `/run/thinkpad-power.lock` around
every state-changing subcommand (the `THINKPAD_POWER_LOCKED` export keeps the
nested `auto -> ac|battery` call from deadlocking on its own lock),
`remove_gpu_functions` treating a vanished function as success and testing the
postcondition instead of the write, and `unblock_if_gpu_present` so no failure
path can ever lift a block while the card is off the bus.

**13. The tunables are not where the watts are.** `extras` now also parks
runtime PM on PCI devices the drivers left pinned (recorded in
`/run/thinkpad-power.runtime-pm` so AC restores exactly those, rather than
forcing the whole bus to `on`). Real but small. The measured budget on this
machine at 15.7 W, dGPU already off: the 3840x2400 panel and the browser
dominate, the connected 5G modem is next, and every kernel knob together is
worth about a watt. PCIe ASPM is deliberately **opt-in** — `ASPM_ON_BAT=powersave`
in `/etc/thinkpad-power.conf` — because forcing L0s/L1 on every link can hang
an NVMe that is merely ASPM-tolerant, and this machine has had enough hangs.

**14. An unquoted heredoc runs the backticks in it.** The add-on's installer
appended config with `cat >>"$HYPR_CONF" <<LUA`, unquoted so its variables
would expand. A comment written as `` `thinkpad-power run` `` was therefore
command substitution: it ran mid-install, printed `error: run needs a program`,
and spliced its empty output into the user's Hyprland config. Nova ships those
files as files and generates nothing at install time, but the rule holds for
every script here: quote the delimiter (`<<'EOF'`) unless the body must expand,
and then put no backticks in it.

**15. Bringing the card back has to work when it is already off the bus.**
Once the policy has done its job there is nothing in sysfs for `detect_nvidia`
to find, so the add-on's installer concluded the machine had no discrete GPU
and refused, on every second run. Firmware always enumerates the card at boot,
so `thinkpad-power` records its address then, in
`/run/thinkpad-power.nvidia-pci`, and reads it back for the rest of the boot.
`NVIDIA_PCI` in `/etc/thinkpad-power.conf` still wins when it is set.

**16. The OC mailbox is locked here — measured, not assumed.** Writing −5 mV
to the CPU-core plane through MSR `0x150` command `0x11` and reading it back
returns **+0.0 mV**. It does not fault; it accepts the write and discards it.
Plane 3 answers command `0x10` with status `0x5`, so the mailbox is alive and
responding, it just will not take offsets. `MSR_PLATFORM_INFO` bits 28 and 29
are *set* (programmable ratio limit and TDP), which is misleading — they do
not imply the voltage mailbox is open. That closes the AC loadline question
too: loadline is a different command to the same mailbox behind the same lock.

**Test it correctly or not at all.** The first probe wrote a *zero* offset,
read zero back, and concluded "unlocked" — which is worthless, because a
locked mailbox that silently discards writes returns the identical result. It
also masked off bits 63:32 of the response, which is where the status code
lives. Only a **non-zero** round trip distinguishes accepted from discarded.

The safe lever is the RAPL sustained limit instead. Firmware leaves PL1 at
109 W and PL2 at 135 W **on battery** — the AC figures, against a 45 W part.
`PL1_ON_BAT` caps it, and also shortens the averaging window from the
firmware's 56 s to 10 s: PL1 is an average, so without that a burst lasting
most of a minute escapes the cap entirely. Measured under 16 threads of load
with PL1 already at 30 W, draw was past 31 W and still climbing at t+20s.

**17. What is left is in use, not misconfigured.** `thinkpad-power doctor`
reads the PMC latency-tolerance table, which names whatever forbids the deep
package states. Here: xHCI at 500 ns-scale 499712 ns — the Bluetooth mouse
(`8087:0032`, `btusb`, USB `3-14`) — and HD audio at 363520 ns, but only while
something plays; `00:1f.3` is suspended otherwise. Neither is reclaimable
without giving up the device. Package C2 sits above half of cumulative
residency for that reason, not because something is set wrong.

Ruled out, so nobody re-tries them: **PSR is already on** (PSR1 enabled, IDLE;
the panel reports `PSR = yes [0x01]` and no Panel Replay, so PSR2 is not
available — `enable_psr=-1` is already doing the right thing). **VRR does not
exist on this panel** (`vrr: false`, no `vrr_capable`). **The Tiger Lake GBE
LTR erratum does not apply** — there is no Ethernet controller. **Hardware
video decode already works** (iHD installed, `LIBVA_DRIVER_NAME=iHD`, Chrome
holding `renderD129`, ~40% of *one* core for 4K-panel YouTube where software
decode would be 300%+).

The one untried lever: EDID declares `Monitor ranges: 48-60 Hz V`, so a fixed
48 Hz mode is within spec even though only `3840x2400@60` is advertised. It is
a display-mode change, which is the single class of change that can cost a
login, so it belongs in Hyprland's config where it can be tested live and
reverted — **not** in this tool. *(Derived in fact 33; and see fact 31 — the
decode was fine, the composite pass was not.)*

**18. `doctor` shipped broken because "it errored out" was mistaken for
"it ran."** Its LTR column read `$(NF-1)`, which is `LTR_IGNORE`, not the snoop
time, so every row printed `PMC0:XHCI  LTR_IGNORE: ns`. It survived two commits
because the only invocation during development hit the root guard, and that was
treated as having exercised it. A guard firing tests the guard. Anything with
an `awk` program in it gets run against a fixture of real input —
`test/roundtrip.sh` is where that goes.

**19. The initramfs was carrying the NVIDIA driver, and the driver drags 109 MB
behind it.** mkinitcpio pulls in the firmware a module *declares*, and
`nvidia.ko` declares four GSP blobs under `nvidia/610.57.04/` — a 109 MB
directory. The usual NVIDIA setup writes `MODULES+=(nvidia nvidia_modeset
nvidia_uvm nvidia_drm)` into `/etc/mkinitcpio.conf.d/nvidia.conf`, which is
right on a machine whose displays hang off the NVIDIA. Here the panel is on the
iGPU and the policy removes the card entirely, so the driver was being loaded
early, at maximum cost, for a device that renders nothing. The boot loader reads
the whole UKI off vfat before the kernel starts, so it is paid every boot:
**9.1 s in Limine against 11.5 s of firmware POST**, with the ESP 76% full.
Nova's initramfs (`data/boot/mkinitcpio/10-nova.conf`) never loads NVIDIA early,
and nothing in Nova writes that file. If one ever appears, a backup of it must
not end in `.conf`: mkinitcpio sources every `*.conf` in that directory.

`kms` **stays**: it early-loads i915, so the firmware logo hands straight over
to the compositor. `nouveau` is already blacklisted by `nvidia-utils`, and
autodetect cannot see the card while it is off the bus, so nothing pulls its
firmware in either.

**20. 4 s of every boot was provisioning a TPM key nothing reads.**
`systemd-tpm2-setup-early` (2.10 s) and `systemd-tpm2-setup` (1.99 s) sit on the
critical chain — `sysinit.target` waits for them, and together they are 4.1 s of
a 6.0 s userspace. They provision the SRK for TPM-bound disk unlock. There is
**no LUKS volume on this machine** (`nvme0n1p2` is plain btrfs), no pcrlock
policy, and the SRK has been cached since install, so this was not first-boot
generation — it was 4.1 s per boot for a key with no consumer. Nova skips both
with a drop-in, `ConditionKernelCommandLine=nova.tpm2`
(`data/systemd/system/tpm2-setup.conf`), so adding `nova.tpm2` to the command
line brings them back for TPM-bound disk unlock. They are `static` units:
`disable` is a no-op, so a condition or a mask is the only thing that works.

**21. `systemd-analyze`'s boot split does not add up here — use the loader's own
numbers.** It reported `11.4s (firmware) + 14.7s (loader)`, but
`LoaderTimeExecUSec - LoaderTimeInitUSec` is 9.1 s. The kernel's printk clock
starts at ~6.7 s on this machine rather than 0, which skews everything
`systemd-analyze` derives from it. The two efivars are written by Limine itself
and reconcile exactly with a stopwatch: 11.5 + 9.1 + ~5.7 + 6.0 ≈ 32 s. `doctor`
prints the two trustworthy ones. They are ASCII decimal behind the four
attribute bytes every efivarfs file carries.

**22. The slow wake is not the kernel.** Low-level resume to `PM: suspend exit`
is **188 ms**. The ~5 s is three devices failing to resume, and the lock screen
waiting behind them:

| | |
|---|---|
| `mhi-pci-generic 0000:08:00.0` | `failed to resume device: -22`, then a full `device recovery` and power-on cycle; the wwan ports disconnect and re-register |
| `xhci_hcd 0000:00:0d.0` | `xHC error in resume, USBSTS 0x401, Reinit` — the Thunderbolt controller reinitialises, so usb1/usb2 report `root hub lost power or was reset` |
| Synaptics `06cb:00f9` | the fingerprint reader drops off the bus and takes ~500 ms to re-enumerate; `fprintd` then logs `Device reported an error during verify: device was disconnected` and the lock screen's PAM conversation fails with `code 9` and restarts |

The one that is actually *felt* is the fingerprint reader, because it gates the
unlock. The modem is background unless something is waiting on the network.

**23. The slow wake is the fingerprint reader, and mostly not the kernel's
fault.** Measured on resume 2 of boot `aea39391`:

| offset from `PM: suspend exit` | |
|---|---|
| +0.13 s | PAM attempt 1, `device was disconnected` |
| +0.42 s, +0.69 s | attempts 2 and 3, `code 9` |
| **+1.04 s** | attempt 4 catches a live device — **the system is done here** |
| +5.76 s, +7.07 s | `Failed to match fingerprint`, twice |
| +7.96 s | `Authenticated successfully` |

So there are two problems and only the first is ours. The retry storm is the
reader losing power in S3 and re-enumerating (~650 ms) while the lock screen
is already asking for it; `FINGERPRINT_WAKE=on` writes a udev rule marking it
wake-capable so the port stays powered. Off by default — it costs sleep power,
and whether the platform honours it is unproven here. The match failures are
the bigger half and no knob touches them: **only `right-index-finger` was
enrolled**, so a slightly-off placement fails. `bmAttributes` is `0xa0`, bit 5
set, so the device does advertise remote wakeup — that is what makes the
attempt worth making rather than obviously futile.

Also on every resume, neither gating the unlock: the 5G modem
(`mhi-pci-generic 0000:08:00.0`) fails with `-22` and does a full recovery
cycle, and the Thunderbolt xHCI (`0000:00:0d.0`) reinitialises with
`USBSTS 0x401`, so usb1/usb2 report `root hub lost power or was reset`.

**24. Theming the boot path is not this tool's job.** Limine and Plymouth used
to drift from the desktop theme, and fixing that was never power management.
Nova settles it by drawing no boot surfaces at all: Limine is
quiet with a 1 s timeout and there is no Plymouth. The split the user drew still
holds: sleep and boot *timing* belong here because they are time and power;
*colours* do not.

**25. Keeping the fingerprint reader powered through suspend is measured
harmful. Do not re-try it.** `bmAttributes` is `0xa0`, bit 5 set, so the reader
advertises remote wakeup, and enabling `power/wakeup` did cut the PAM retry
storm from 4 to **1**. It also broke the reader outright. Over a 63 min S3
suspend on 2026-08-28:

```
14:09:44.503  fprintd: Ignoring device due to initialization error:
                       unsupported firmware version
```

fprintd rejected the device, so fingerprint unlock did not work at all on
resume — the user fell back to a password 40 s later. The reader is fine again
once fprintd restarts (it is D-Bus activated), which is what makes this look
intermittent rather than caused. Trading a working unlock for 0.9 s is the
wrong trade at any price, so the knob and its udev rule are **removed**, not
defaulted off. `power/wakeup` resets to `disabled` on re-enumeration, so a live
test never survives a reboot and cannot strand the machine.

**26. The first real sleep measurement: S3 costs 1.26 W.** 63 min suspend,
52.22 Wh to 50.38 Wh, minus 3.6 min awake at ~11 W:

| | |
|---|---|
| asleep | 1.05 h |
| used asleep | 1.33 Wh |
| **S3 drain** | **1.26 W** |
| a full battery at that rate | 74.5 Wh / 1.26 W ≈ **59 h**, call it 2.5 days |

That is worse than the 0.8–1 W this was guessed at, and it makes the case for
`suspend-then-hibernate` **stronger**, not weaker: a closed lid flattens the
battery over a long weekend. Caveat, so the number is not over-trusted: the
fingerprint `power/wakeup` experiment was live for this measurement, so 1.26 W
is an upper bound and a clean re-measure is owed.

**27. Wake to a *lit screen* is not the same as wake to a working session.**
The kernel is done fast — `PM: suspend exit` at +0.21 s — and the journal then
goes quiet for two seconds. Panel power-on and the compositor's first frame are
not logged anywhere, so the 3–4 s before anything appears cannot be attributed
from the journal and was not, in fact, measured by the +1.04 s figure in fact
23. That figure is time-to-PAM-prompt, which is a different thing from
time-to-visible.

The modem's `mhi_wwan_ctrl mhi0_MBIM: Failed to queue buffer` is loud — 114
lines — but takes 90 ms, so it is noise, not latency.

**28. The lock screen blanks after 5 s, by design.**
`src/shell/plugins/lock/Service.qml` has `idleBlankTimer.interval: 5000`, which
runs `nova-brightness-display off` (and the same for the keyboard backlight).
It re-arms once across a resume, so it reads as ~10 s after opening the lid. It
is a constant in that file, not a setting. It is only ever noticed when
unlocking is *already* broken, so fix the unlock first.

**29. Hibernate resume leaves the discrete card powered and invisible, and
nothing reports it.** A hibernate is a full power cycle: firmware enumerates
`01:00.0` again on the way back up, but the image being restored was taken with
the card off the bus, so the restored kernel has no record of it, never touches
it, and it sits in D0 drawing the ~6 W this tool exists to save. `gpu_off` sees
no device and reports "already off the bus" — exactly the reassuring message it
prints when everything is fine. `post-hibernate` rescans first so the policy has
something to remove. The modprobe block lives in `/run`, which is tmpfs and
therefore *inside* the hibernation image, so it is still in force at that point
and the rescan cannot pull the driver in — which is what makes this safe against
fact 10 rather than another route into it.

It fires only on the hibernate half. `SYSTEMD_SLEEP_ACTION` is the only thing
that distinguishes them: with `suspend-then-hibernate` the machine may have
woken from either half, `$2` says `suspend-then-hibernate` either way, and
`hibernate.target` is never separately activated, so no unit ordering can tell.
NVIDIA's own `/usr/lib/systemd/system-sleep/nvidia` keys on the same variable.
`suspend-after-failed-hibernate` is deliberately *not* matched: it means the
hibernate did not happen, so there was no power cycle. On an ordinary S3 resume
a rescan would bring the card back only to take it away again, on every resume,
adding a second or two to a resume already complained about.

**30. `HibernateOnACPower` defaults to yes, which is wrong here.** Left alone,
systemd would hibernate a machine sitting on a charger — paying a full POST to
resume in order to save power that is not being drawn from anything. Set to
`no`, so plugged in stays an ordinary suspend.

**31. The video lever was compositing, not decoding.** Fact 17 recorded that
hardware decode already works and left it there, which was half the picture: the
decode was free and the *presentation* was not. With `render:direct_scanout` at
Hyprland's default of `0`, a fullscreen video is composited into a fresh
3840x2400 buffer and blitted every frame — the largest single thing the iGPU
does during playback, for a surface that could have gone straight to the display
controller. `hyprctl monitors` names it: `directScanoutBlockedBy: user settings`.

It has to be `1`. `2` is "auto", which engages only for surfaces whose content
type is `game`; a video is tagged `video` and would never qualify. Hyprland
drops back to compositing on its own the moment anything must be drawn over the
fullscreen surface — a notification, the bar, a screencopy client — so there is
no correctness cost to leaving it on. It is set in Nova's Hyprland module for
this model, `default/hypr/hardware/thinkpad-p1-gen4i.lua`.

Decode itself was re-verified rather than trusted, because there is no `vainfo`
on this machine: a ctypes probe on `libva.so.2` + `libva-drm.so.2`
(`vaGetDisplayDRM` on `renderD128`, then `vaQueryConfigProfiles`) reports iHD
26.2.4 with `VLD` on H264, VP9 profiles 0-3, the HEVC family and **`AV1Profile0`**,
and `iHD_drv_video.so` is mapped in Chrome's GPU process. So AV1 from YouTube is
hardware-decoded here and h264ify-style codec forcing would cost power, not save
it. Write the probe, do not assume — this is the same rule as the EGL/Vulkan
probes.

**32. The usual argument against Wi-Fi power save is about a different chip.**
Some distributions turn it off for every machine (`wifi.powersave = 2`), for
two reasons: 20-300 ms latency spikes on an idle link, and Intel
**BE200/BE211** firmware that drops the link when the radio naps. The radio here is an **AX210**
(`8086:2725`, Typhoon Peak) — not one of those parts — and the latency is only
felt by interactive traffic, which a page load and a video stream are not. So
the policy sets it on for battery and off on AC.

The trap is that NetworkManager writes the flag at **every connection
activation**, so a roam, a reconnect or a resume silently reverts it and
`thinkpad-power status` would be the only place it showed.
`/etc/NetworkManager/conf.d/nova-hw-wifi-powersave.conf` sets
`wifi.powersave = 1` ("ignore") to stop that. conf.d is read in plain
alphabetical order and the last file wins, so another file that sets the flag
and sorts after it would undo it; Nova ships no other.

`WIFI_POWERSAVE_ON_BAT` is the one tunable here that defaults to **on**. Its
failure mode is latency, not a hang, which is what separates it from `ASPM_ON_BAT`.

**33. The 48 Hz mode has to stretch blanking, not slow the clock.** Fact 17
called this the one untried lever and it is now derived, though still untried.
The EDID says `Display supports continuous frequencies`, `48-60 Hz V`,
`148-148 kHz H`, max dotclock 600 MHz; the DTD is 3840x2400 at 592.56 MHz,
htotal 4000, vtotal 2469. Because the horizontal rate is **pinned** at
148.14 kHz, the only in-spec 48 Hz mode keeps the pixel clock and extends
vertical blanking to 148140 / 48 = 3086 lines — the vertical back porch going
from 60 to 677. Slowing the pixel clock instead, which is the obvious way to do
it, drops the horizontal rate to 118 kHz and outside what the panel declares.
That gives:

```
modeline 592.56 3840 3888 3920 4000 2400 2403 2409 3086 +hsync -vsync
```

It is worth ~20% of every per-frame cost while anything animates, and 24 fps
video lands in a 2:2 cadence. It also makes scrolling visibly less smooth, and
it is still a display-mode change, so it was tried as a key binding that writes
nothing: live-only is what makes a mode change safe to try, because if the
panel refuses it, a reload or a logout is already the fix. Fact 39 measured it,
and Nova does not ship the binding.

**34. PL1 was half the CPU story, and the ceiling was none of it.** Fact 16
capped the sustained limit and stopped there. Two things were left:

*PL2.* Firmware sets the burst limit to 135 W against a 45 W part, over a
2.44 ms window. The *energy* in one such burst is trivial — 135 W for 2.44 ms is
0.33 J — so it never showed up in a watt-hour measurement, and it is exactly
where the fan noise and the hot palm rest come from. `PL2_ON_BAT` caps it. A
value below PL1 is refused rather than written, and PL1 is still applied when
PL2 is refused: dropping the knob that matters under load because the other one
was mistyped is the wrong failure.

*The frequency ceiling.* Under HWP with EPP already at `power`, `intel_pstate`
still walks to the top of the range to scroll a page — `max_perf_pct` was 100,
the range tops out at 4.8 GHz, and `turbo_pct` is 57, so anything below ~43
removes turbo outright. `CPU_MAX_PCT_ON_BAT` is a ceiling, not a target;
nothing gets slower until something asks for more than the ceiling.

*And therefore `boost`.* A ceiling is only tolerable with an escape hatch,
because the thing that genuinely wants 4.8 GHz is a compile. `boost [minutes]`
lifts both CPU caps and schedules its own expiry with `systemd-run` **before**
lifting anything, so a scheduling failure leaves the machine capped rather than
uncapped forever. The marker is `/run/thinkpad-power.boost` and *both* CPU
tunables check it before their battery branch — without that, the resume hook,
a replug or the retry timer would re-apply the caps in the middle of a build
and print nothing. That guard is the interesting part and is what the round-trip
test covers; the dispatch around it is not testable from the library half.

EPP and the platform profile are still left to power-profiles-daemon (fact 4),
and `thermald` is installed but not running — it drives the same RAPL
constraints, so leaving it stopped is what makes `status -v` mean what it says.

**35. The CPU wanted a daemon, and this is why.** RAPL gives you the exact
opposite of what a laptop wants. PL1/PL2 is "high briefly, low sustained": a
burst gets 135 W and a long job gets throttled. What is wanted is "low briefly,
high sustained" — a browser must never reach 4.8 GHz to scroll, a compile must
have everything. No register does that, because it is a policy about *time*,
and a policy about time needs something awake to watch the clock. Hence
`thinkpad-powerd`, in `daemon/`, Rust, std only.

Three tiers on battery (light 12/20/50, mid 20/32/75, full 30/45/100), a dwell
of 8 s above 65% busy before climbing and 25 s below 30% before falling. The
dwell is the whole design: it is longer than any interaction, so a spike cannot
buy a tier, and a build's gaps between files cannot lose one. The band between
the two thresholds is dead on purpose — a load hovering on the line would
otherwise oscillate. `iowait` is not counted as busy: a build waiting on the
NVMe is not asking for frequency.

What it owns is exactly PL1, PL2, `max_perf_pct` and the fans. EPP and the
platform profile are still power-profiles-daemon's (fact 4). The bash half
stands down on all four while `/run/thinkpad-powerd.owns-cpu` exists, so there
is one writer at a time — that marker is the whole coordination protocol.

**Fans, and the three lines of defence.** `FAN_CONTROL` defaults on but is
gated on `thinkpad_acpi` having been loaded with `fan_control=1`, which
`/etc/modprobe.d/nova-hw-thinkpad-fan.conf` sets and which is read only when the
module loads; until then it is a no-op with one line of explanation rather than
a knob nobody finds. The battery
curve is deliberately *lazier* than the EC's below 70 C, because a warm chassis
is cheaper than a spinning fan. Then: the daemon releases to `auto` above
`GOVERNOR_TEMP_CRITICAL` before the curve is consulted at all, so no arrangement
of curve entries can hold a low level on a hot package; systemd's `ExecStopPost`
runs `thinkpad-power daemon-stopped` for the kill -9 case; and the EC's own
watchdog, refreshed every ~10 s, takes the fans back about thirty seconds after
this process stops existing, needing nobody. The level is re-asserted on every
watchdog refresh rather than only on change, because the EC silently takes the
fans back across a resume and a cache would never notice.

**36. The first firmware capture recorded the cap.** `thinkpad-powerd` reads
PL1 at startup to know what to restore on AC. Run for the first time on battery
with the bash half's `PL1_ON_BAT=30` already applied, it recorded **30 W** as
"what the firmware wanted" — after which plugging in would "restore" to 30 W,
and there is no route back short of a reboot. Caught by reading its own first
log line against `/etc/thinkpad-power.conf`.

The fix is that the bash half already saves the true values, in
`/run/thinkpad-power.rapl` and `/run/thinkpad-power.cpupct`, for exactly this
purpose — so those are consulted first and the live registers only when neither
exists. The capture is then persisted to `/run/thinkpad-powerd.firmware` so a
daemon *restart* does not repeat the mistake against its own tiers. Three files,
one question: what did this machine look like before anything here ran.

**37. A manual GPU switch-on used to last two minutes.** `gpu-auto` runs every
2 min and did `if on_ac; then gpu_on; else gpu_off; fi`, so turning the card on
by hand on battery was undone by the retry timer — `switch` even said so, which
made it documented rather than fixed. There is now
`/run/thinkpad-power.gpu-manual`, and the detection needs no flag: **the policy
only ever calls `gpu_on` while on AC**, so a `gpu_on` that happens on battery
can only be somebody asking for it. An explicit `gpu-off` cancels it, plugging
in cancels it, and /run means a reboot forgets it.

**38. Sleep is correct, and hibernate has now actually run.** Fact 26 left this
open and the journal closes it: suspended 18:18:38, held S3 for exactly the
configured 2 h, `Performing sleep operation 'hibernate'` at 20:18:42, resumed
21:11:14. `suspend-then-hibernate` works end to end, `HandleLidSwitch` is live
over D-Bus, `mem_sleep` is `deep`, and `resume=`/`resume_offset` match
`/sys/power/`. zram sits at priority 100 above the swapfile, which is right for
ordinary swap and irrelevant to hibernation because `/sys/power/resume` names
the file explicitly.

One thing found and **not** changed, because it is a judgement call:
`nvidia-utils` ships
`/usr/lib/systemd/system/systemd-{suspend,hibernate,hybrid-sleep,suspend-then-hibernate}.service.d/10-nvidia-no-freeze-session.conf`,
setting `SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=false`. systemd warns about this on
every single sleep, and names suspend-then-hibernate as the case it is most
likely to break. On this machine the argument for the drop-in is thin —
`HibernateOnACPower=no` means hibernation only ever happens on battery, and on
battery the card is off the bus with the driver unloaded, so it is disabling a
systemd safety for a driver that is not there. Overriding it back to true is one
drop-in of our own. It was left alone because plain suspend *on AC* can happen
with the driver loaded, which is the case the NVIDIA file is actually for.

**39. 48 Hz is measured and it is not worth it. Do not re-try it.** Fact 33
derived the mode; this measured it. Paired, alternating samples on battery:

| | 60 Hz | 48 Hz |
|---|---|---|
| round 1 | 20.46 W | 19.83 W |
| round 2 | 19.36 W | 19.67 W |
| mean | **19.91 W** | **19.75 W** |

0.16 W apart, against 1.1 W of spread *within* a single mode. That is not a
result. It is also the expected one in hindsight: a compositor only redraws on
damage, so on a static desktop the refresh rate costs almost nothing, and the
20% saving is 20% of the frames that are actually drawn — which is nearly none
while reading. It may still be worth something during continuous animation, but
that has not been measured; the command below sets it live for anyone who wants
to try.

**`hyprctl keyword` does nothing under the Lua parser.** It answers *"keyword
can't work with non-legacy parsers. Use eval."* and changes nothing, which is
indistinguishable from a panel refusing a mode. The bindings shipped broken for
exactly this reason and were only caught because the measurement showed
`refreshRate: 60.00000` after the command reported success. Use:

```
hyprctl eval 'hl.monitor({ output = "eDP-1", mode = "3840x2400@48", position = "0x0", scale = 2 })'
```

Asking for plain `3840x2400@48` and asking for the full modeline both land on
**47.958 Hz**, so the driver derives the same timing either way and the short
form is the one worth keeping.

**40. The backlight is not the problem, which is worth knowing before chasing
it.** Measured on battery, everything else held: **5% → 16.68 W, 15% (the usual
setting here) → 18.58 W, 100% → 20.90 W.** The entire range is 4.2 W and the
usual setting is already near the bottom of it. A 4K panel's backlight is the
first thing everyone blames; on this machine there is about a watt left in it.

**41. Two measurement traps, both self-inflicted, both silent.**

`pkill -f "/opt/google/chrome/chrome"` **matches the shell running it**, because
that string is in its own command line. `pkill -STOP` with that pattern
therefore SIGSTOPs the measuring script along with the target, which looks
exactly like a hang, and the tool times out with the browser still frozen. Take
the PIDs first (`PIDS=$(pgrep -f ...)`) and then `kill -STOP $PIDS`, which
cannot match by name. Do not SIGSTOP a live browser to measure it at all —
doing so here cost a Chrome session and produced a nonsense result (21.45 W
frozen against 20.70 W running) because the window was polluted by the
measuring itself.

`read -t N </dev/null` returns **immediately** — /dev/null is instant EOF, not
an idle fd. A sampling loop built on it runs every iteration inside one second
and prints a column of identical numbers that reads like a stable measurement.
Use `sleep`, and distrust any sample where every row is identical.

**42. What the machine actually costs, and what 12 W means here.** Measured
with the dGPU off the bus, backlight at 90/600:

| | |
|---|---|
| quiet desktop, little running | **15.3 W** |
| Chrome open and idle | **16.4 W** |
| Chrome busy, ~29 renderers, plus a coding agent in a terminal | **19-21 W** |

The figures this machine was known by before agree: ~12 W coding, ~19 W browser. **12 W is the
coding number and it is already met; 12 W while browsing is not reachable on
this hardware.** Chrome's GPU process alone measured 24.4% of a core presenting
a windowed video, with Hyprland a further 9.4% — that is watts, and no kernel
knob touches it. The levers that remain are all in the browser: fewer tabs,
Memory Saver discarding the idle ones, and Energy Saver throttling what is left.
Everything this repository manages below the browser is already spent.

**43. The Chrome policy works, and `chrome://policy` is the only honest check.**
Verified on this machine: `BatterySaverModeAvailability: 2` and
`HighEfficiencyModeEnabled: true` both report **OK / Platform / Machine /
Mandatory**. So 2 really is "enabled whenever on battery" and the value is
accepted — that was documented behaviour being trusted until this, not
something measured. Nova does not pin them: the add-on only wrote the policy
when asked, a mandatory policy takes both switches away from the user, and both
are two clicks in `chrome://settings/performance`.

Two things that look like failures and are not. First, `Local State` keeps
showing `"battery_saver_mode":{"state":0}` *after* the policy is live: a
mandatory policy lives in the managed pref store and overrides the user pref
without rewriting it, so reading Local State can never tell you whether a policy
is in force. Only `chrome://policy` can. Second, platform policy files are read
at **startup** — Chrome had been running 26 minutes since before the file was
written and had simply never seen it.

**A policy file must contain nothing but policy names.** Chrome validates every
key against its policy list and gives an `Error` row to anything it does not
recognise. The first version of this file carried a `"_comment"` key explaining
itself, which earned a permanent red row in the user's `chrome://policy` next
to two OK ones. There is no comment syntax in JSON and no comment key in
Chrome's schema; the explanation belongs in the filename and in whatever writes
it. Nova's own policy file, the theme colour, holds one key for this reason.

**44. The GPU policy was half-blind, and it is why "turn it off" mostly did
not.** `gpu_users` scanned `/dev/nvidia*` and nothing else. But with
`nvidia-drm modeset=1`, which PRIME offload needs, the card *also* registers a
DRM device. An open fd
on that node pins `nvidia_drm` exactly as hard as an fd on `/dev/nvidia0`, and
the policy could not see it. So it reported nothing holding the card, tried the
unload anyway, and failed with a message that named nobody.

The fortnight in the journal, which is what turned this from a hunch into a
count:

| | |
|---|---|
| `nvidia_drm would not unload` | **96** |
| `dGPU in use by ... (btop)` | 85 |
| `dGPU in use by ... (nvidia-powerd / nvidia-smi)` | ~120 |
| `dGPU removed from the PCI bus` | **15** |

Proved without needing the card back on the bus, by pointing `gpu_drm_nodes` at
the *iGPU* — which is on the bus — and running the real `fuser`: it names
Hyprland, Xwayland, `xdg-desktop-portal`, quickshell and two Chrome processes.
Under the old code all seven were invisible. The nodes are read off the device
(`$SYS_PCI/$NVIDIA_PCI/drm/`) rather than assumed to be `card0`, because DRM
numbering is probe order and does not survive a reboot.

`modeset=1` was **not** removed, and should not be. It is what makes DRM PRIME
buffer sharing work, which is what `thinkpad-power run` needs on Wayland. The
blind spot was the bug; the option is not.

**45. Two of the three failure modes were reachable without any of that.**

*The boot race.* `thinkpad-power.service` runs about a second into boot, loses
to whatever still has the card open that early, and then hands the question to
a timer that comes back in **two minutes** — with the card powered for the
whole gap, every boot. The holders that early are transient by nature, so
`unload_nvidia_modules` now retries six times a second apart before declining.
On the 2026-09-04 boot the timer's first retry succeeded at 11:35:47, 118 s
after the failure at 11:33:49, and 30 s after the login that released it.

*`nvidia-powerd` counted as a holder.* `stop_nvidia_services` skipped the stop
whenever `is-active` said inactive — but the unit is `Restart=on-failure` with
`RestartSec=10`, so a unit caught between a crash and its restart reports
inactive while its process is alive and still holding the card. It has appeared
**twice in one holder list**, which is what that looks like from outside. The
stop is now unconditional; it is a no-op when there is nothing to stop.

*What is left is btop, and it is genuinely the user's call.* 85 declines in a
fortnight. It reads NVML every couple of seconds through `dlopen`, which opens
`/dev/nvidia*`, so unplugging with btop open leaves the card powered until it
is closed — the policy declining correctly rather than pulling the card from
under a running program. `shown_gpus = "intel"` in `~/.config/btop/btop.conf`
stops it touching NVML at all, at the cost of GPU stats on AC. Not changed
here; fact 42's rule holds — the browser and the user's own programs are not
this tool's to decide.

**46. The awk in `module_refs` is covered, and so is the removal path.** Field
3 of `/proc/modules` is the reference count and field 4 the *modules* holding
those references; a count above zero against `-` means the holders are open
file descriptors, which is the case worth naming. `test/roundtrip.sh` drives it
against a fixture of real `/proc/modules` output, and drives the retry with
`modprobe` and `sleep` shadowed — including the partial-unload state, where one
module survives and `gpu_off` must not conclude it is finished. 84 checks.
`SYS_PCI`, `DEV_DRI` and `PROC_MODULES` are overridable globals now, for the
same reason every `/run` path already was.

Trap found writing those tests, in the test and not the tool: `grep -v` exits
**1** when it filters out every line, which is exactly what removing the last
module looks like. The shim's `&& mv` therefore never ran and the fixture kept
the module, which reads as the unloader failing.

**47. A per-user step run under `sudo` configures root, and still reports
success.** The add-on's installer wrote four session files — the compositor's
GPU pin, a Hyprland block, a menu entry and a remembered battery profile —
under `$HOME`, which under `sudo` is `/root`. Nothing reads `/root/.config`, so
the session half of the install did nothing at all while printing a tick for
every step:

```
  ✓ /root/.config/uwsm/env-hyprland (pins the compositor to /dev/dri/igpu)
```

Nova has no such step: the session files are system files in the package (the
uwsm `env.d` file and the Hyprland hardware module), and the one piece of
per-user state, the remembered power profile, is written by the session itself.
The rule stands for anything here that writes into a home while running as
root: recover the account from `SUDO_USER`, and chown back what is created
there, since a root-owned file in the user's home breaks the next run as the
user.

**48. Fact 44's fix inverted itself: the DRM card node is held by logind
forever, so the policy declined every single time.** Adding the DRM nodes to
`gpu_users` was right about the blind spot and wrong about which half of it
matters. The *card* node is the KMS node, and on any logind system it is open
for the life of the session by processes that are not using the GPU at all:
`systemd-logind` opens every DRM device on the seat so it can revoke and
restore them across VT switches, PID 1 inherits it, and aquamarine opens each
card once to ask whether it supports KMS **before** it applies
`AQ_DRM_DEVICES`, then drops the rejected ones without closing them —

```
libseat: Device /dev/dri/card0 supports kms
drm: Explicit device list /dev/dri/igpu
drm: Found 1 GPUs
```

— so pinning the compositor to the iGPU cannot prevent it; the open happens
before the filter. `fuser` on the card node therefore returns `1 (systemd) 814
(systemd-logind) 1393 (Hyprland)` on a completely idle card, forever. Every run
from 11:33 to 16:49 on 2026-09-04 declined with that exact list — the timer
failing every two minutes for five hours, card powered throughout.

The method error in fact 44 was proving it against the **iGPU**: the seven
holders that turned up there hold the *integrated* nodes because they render on
it, which says nothing about the discrete card. Pointed at the real dGPU node,
the answer is infrastructure, not users.

And those fds block nothing, which the arithmetic settles: **four** fds were
open on `card0` — Hyprland twice, PID 1, logind — while `nvidia_drm` sat at
`refs: 1`. Opening the card node contributes no module reference at all. The
card node *explains* a failed unload; it never *predicts* one.

So the two questions are split. `gpu_consumers` — `/dev/nvidia*` plus the DRM
**render** node — is the only thing that may veto a switch-off, and it is what
`status`, `switch` and `gpu_off` now ask. `gpu_users` keeps the wide list and
is used in exactly one place: naming holders after `unload_nvidia_modules` has
actually failed. The unload is the authority on whether the card can go; it
fails safely with `EBUSY`, and gating it on a test that is permanently true
only meant never asking.


**49. The reference nothing holds is `nvidia_drm` holding one on itself, and
`fbdev=1` is why.** Fixing fact 48 got the policy as far as *attempting* the
unload, and it still failed on a completely idle card:

```
nvidia_drm would not unload (refs: 1, held by -)
held by 1 (systemd) 814 (systemd-logind) 1393 (Hyprland)
```

`held by -` means the references are open file descriptors rather than another
module — but there were four fds on `card0` against a refcount of 1, so they
were not it. The refcount is a *self*-reference. With `nvidia-drm fbdev=1`, the
driver registers a DRM fbdev client at load, and `drm_client_init()` does
`try_module_get(funcs->owner)` where the owner is nvidia_drm. The card is
pinned from the instant the driver loads, and no process is ever named because
none is involved.

The boot log is the clean proof, because it brackets the compositor:

```
11:33:48 kernel: [drm] [nvidia-drm] [GPU ID 0x00000100] Loading driver
11:33:49 thinkpad-power[830]: nvidia_drm would not unload
11:35:13 Hyprland starts
```

The unload failed 95 seconds before Hyprland existed. Every "in use by
Hyprland" line this tool ever printed was a misattribution twice over — the
wrong holders, for a reference none of them held.

`fbdev` is the framebuffer console on the discrete card, and this laptop wires
no displays to it: the kernel says so in the same breath, `nvidia 0000:01:00.0:
[drm] Cannot find any crtc or sizes`. It defaults on in 610.57.04 (the driver
default since 560) and EnvyControl's generated `nvidia.conf` sets only
`modeset=1`, so nothing here ever turned it off. `modeset` stays — fact 44 is
right that PRIME needs it; the two are unrelated options.

Nova's hardware profile installs `/etc/modprobe.d/nova-hw-nvidia-fbdev.conf`
with `options nvidia-drm fbdev=0`, in a file of its own because modprobe merges
options across files and `nvidia.conf` may belong to something else.
`unload_nvidia_modules` also names the condition when it sees it, since
`refs: 1, held by -` on an idle card is otherwise unactionable. **A change to it
needs a reboot** — the parameter is read when the driver loads, and the driver
is exactly what cannot be unloaded.

## Working here

- **CLI conventions.** Messages carry no `thinkpad-power:` prefix: systemd
  already stamps the unit name. `log` for things that happened, `note` for
  things that did not need doing (the retry timer sets `QUIET=1`, so a no-op
  every two minutes is not 720 journal lines a day), `die` for `error: ...` on
  stderr with exit 1. State-changing subcommands refuse up front without root
  instead of letting a dozen sysfs writes fail one at a time. No power figures
  in the CLI: they are approximate and machine-specific. `status` is three
  lines, with diagnostics behind `-v`, and must stay side-effect free: it used
  to call `nvidia-smi`, which wakes the card out of P8 just to answer.
- **Use `sudo thinkpad-power status`** when chasing what holds the card.
  `fuser` reports only processes the caller may see, so unprivileged, the
  root-owned holders are invisible and the list looks reassuringly empty.
- **Prove a driver leak, do not guess it:** a few lines of Python that load
  `libEGL.so.1` or `libvulkan.so.1` through ctypes, then read
  `/proc/self/maps` and `/proc/self/fd`, show exactly what opened the card.
- **The uwsm `env.d` file is sourced by `/bin/sh` at every login.** The unit
  tests parse it and source it; on the machine itself, source it under `sh` to
  see the exported values before anyone logs out: a file that fails there costs
  the login.
- **Sample with `sleep`, never `read -t N </dev/null`,** which returns at once
  (`/dev/null` is instant EOF). A loop built on it runs every iteration inside
  a second and prints a column of identical numbers that look like a stable
  measurement; it produced two bogus results here. Distrust any sample where
  every row is the same.

## Measured

**The dGPU off the bus** on battery: no `0000:01:00.0`, no nvidia modules,
the Intel card the only DRM card. About **6.2 W reclaimed** (19.93 W against
~26 W with the card bound), 3.0 h on a 60.4 Wh charge where it was ~2.3 h.
What finally did it, after three false starts, was NVIDIA's own daemons
holding the card: `nvidia-persistenced` (enabled by the driver package, so
disabled here) and an `nvidia-powerd` started by `gpu_on` itself.

**The governor**, under 16 threads of load on battery:

| | tier | PL1 | ceiling | draw |
|---|---|---|---|---|
| 0 s | light | 12 W | 45%, turbo off | 17.5 W |
| 13 s | mid | 18 W | 70% | 25.4 W |
| 29 s | full | 28 W | 100% | 33.6 W |
| 53 s | turbo | 40 W | 100% | 34.3 W |

Climb intervals of 8 / 16 / 24 s, the progressive dwell; falling took 25 s per
rung. The package went 51 → 59 C and never approached the 85 C throttle. Under
the same full load, light draws 25.4 W where turbo draws 34.3 W: the same
work, gated. The firmware's PL1 was captured as 109 W and restored, and
`gt_max`, `gt_boost` and `no_turbo` followed the tier.

**Sleep:** S3 drains 1.26 W, so a full battery lasts about 59 h asleep; a 63
minute suspend on battery resumed cleanly. **Wake:** the kernel is done 0.21 s
after resume and the lock screen prompts at 1.04 s; the rest of what feels
slow is the fingerprint reader (facts 25 and 27).

**Three hard lock-ups, one root cause.** An idle freeze on battery, a freeze
during `pci/rescan` on plugging in, and a kernel panic when `nvidia` loaded
13 s after the card was removed were all facts 9 and 10: a PCI transaction to
a device inside the dGPU's power domain after that domain is gone, escalating
to a broadcast MCE. Since the fix, removal takes both functions (`01:00.0` and
`01:00.1`), leaves no `/dev/nvidia*`, and bars the driver from loading until
the card is back; `sudo thinkpad-power status -v` shows both.

**Ruled out, so nobody re-tries them:**
- keeping the fingerprint reader powered through suspend: it breaks the reader
  outright (fact 25);
- forcing VP9 or h264ify: AV1 is hardware-decoded here (fact 31);
- `thermald`: it fights the RAPL limits the policy sets;
- turning the 5G modem off on battery automatically: the bar's mobile-data
  switch is the user's call, not a policy to make behind their back.
