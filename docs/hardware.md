# Hardware support

Nova runs on current x86-64 laptops and desktops. This page says what every computer gets, what a laptop gets on top, and which models are tuned further.

## How support works

| | Covers | What it is |
|---|---|---|
| **In general** | current x86-64 laptops and desktops | drivers, power modes, sleep, Settings |
| **A hardware profile** | every computer of one model | packages and settings measured on that model |
| **A patch** | one individual computer | a fix for that computer's own fault ([patches](patches.md)) |

## What every computer needs

- A 64-bit (x86-64) CPU. One with the x86-64-v3 instructions gets Nova's kernel, `linux-nova`; an older one Arch's `linux`.
- UEFI with Secure Boot off; the installer checks both before its first question.
- A disk of 64 GiB or more, which Nova takes whole.

## What the installer picks

| Your computer has | Nova installs |
|---|---|
| an Intel or AMD CPU | its microcode |
| Intel graphics | `intel-media-driver`, `vulkan-intel` |
| AMD graphics | `vulkan-radeon` |
| NVIDIA graphics, GTX 16 / RTX 20 series and newer | NVIDIA's open modules for both kernels, `nvidia-utils`, and video decoding |
| older NVIDIA graphics | nothing more: the open nouveau driver |
| a fingerprint reader Nova can drive | `fprintd`, and the offer to enroll a finger |
| an Intel MIPI camera (IPU6, IPU7) | `libcamera` and its PipeWire plugin |

Every computer also gets `linux-firmware`, recent laptops' sound firmware, and `linux-lts` as the fallback kernel. A 32-bit Vulkan driver for the same graphics comes with Steam.

### Two graphics cards

The desktop runs on the card that drives the screen, usually the integrated one, and the NVIDIA card is used for what asks for it. `nova power gpu run <program>` starts one program on it, and games marked for it start there by themselves. ([Power](power.md#the-discrete-gpu) has the rest.)

### A cellular modem

ModemManager comes with every install and unlocks the modems it knows. A modem that needs its maker's own unlock script (some Lenovo ones) is named by `nova doctor`; put the script in `/etc/ModemManager/fcc-unlock.d`. After that it is Mobile Data in the bar and in Settings.

## What a laptop gets

- **Power modes on battery**: every unplug starts in Power Saver; plugged in is always full power.
- **A charge limit**, where the battery has one, read back after it is set.
- **Sleep that lasts**: a closed lid suspends, and after two hours asleep on battery the computer hibernates, so a weekend in a bag does not drain it.
- **Battery Life** in Settings: the battery's measured runtime and health.
- **An undervolt** for Intel CPUs whose firmware allows one ([power](power.md#undervolting)).
- **A sleeping NVIDIA card**: RTX 30 series and newer sleep by themselves while unused; for GTX 16 and RTX 20, `nova doctor` gives the line that allows it.

## A sharp display

- Wayland apps draw at each display's scale (Settings → Displays).
- X11 apps (some JetBrains IDEs, older Flatpaks) scale by one whole number for all displays, the largest display's rounded up; Nova passes it to GTK, Qt, Electron and Java apps. On a display of a lower scale Nova's Hyprland shrinks them, so they are the same size everywhere, a little softer, never blurry and large.
- `hl.env("NOVA_X11_SCALE", "1")` in `~/.config/hypr/monitors.lua` sets the scale yourself. A `GDK_SCALE` you set turns all this off.

## Tuned devices

A model gets a hardware profile once someone who has it measures what it needs. Today:

| Model | What it adds |
|---|---|
| Lenovo ThinkPad P1 Gen 4i | the power governor (CPU limits and fans to the load, the discrete GPU off the bus on battery), the GPU switch in Settings, its speaker tuning, and every release is tried on it before it is out |

The engineering notes for it, with what was measured and why, are in [the P1's notes](hardware/thinkpad-p1-gen4i.md).

## Hardware profiles

A profile is Nova's data for one model, matched by what the firmware reports. It can hold packages the installer adds and updates keep, settings copied into `/etc` (and removed again when a release drops them), and session settings. A portable Nova takes no profile.

A fault of one computer is never fixed in a profile, and a model's setting is never a patch.

## What your computer has

- **`nova doctor`** names the computer's profile ("the generic setup" when there is none), lists its patches, and checks each graphics card and its driver, Wi-Fi, sound, a camera, missing firmware, Secure Boot and sleep, saying what to install or where to look.
- **Settings → About** shows the model, processor, memory and storage.
- **Settings → Performance** and **Battery** show only what the computer has.
