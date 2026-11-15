# Hardware support

This page covers what Nova runs on, what the installer picks for your computer, what a laptop gets beyond the basics, and how a fault of one computer is fixed.

## How support works

| | Covers | What it is |
|---|---|---|
| **In general** | current x86-64 laptops and desktops | what every computer gets: drivers, power modes, sleep, Settings |
| **In depth** | the Lenovo ThinkPad P1 Gen 4i | tuned and measured on it, and every release is tried on it before it is out |
| **A hardware profile** | every computer of one model | settings and packages for that model, added when someone has one to measure |
| **A patch** | one individual computer | a fix for that computer's own fault, such as a bad memory cell or a quirky device |

A fault of one computer is never fixed in a profile, and a model's setting is never a patch: [patches](patches.md) says why, and how to make one.

## What every computer needs

- A 64-bit (x86-64) CPU. One with the x86-64-v3 instructions gets Nova's kernel, `linux-nova`; an older one gets Arch's `linux`.
- UEFI, with Secure Boot off. The installer checks both before its first question, and stops with nothing changed when one is not so.
- A disk of 64 GiB or more, which Nova takes whole.

## What the installer picks

The installer looks at the CPU, the graphics, a modem, a fingerprint reader and the camera, and adds what they need:

| Your computer has | Nova installs |
|---|---|
| an Intel CPU, an AMD CPU | its microcode (`intel-ucode`, `amd-ucode`) |
| Intel graphics | `intel-media-driver`, `vulkan-intel` |
| AMD graphics | `vulkan-radeon`; Mesa has AMD's video driver built in |
| NVIDIA graphics, GTX 16 or RTX 20 series and newer | NVIDIA's open modules, for the main kernel and the fallback, `nvidia-utils`, and `libva-nvidia-driver`, so the card can decode video |
| NVIDIA graphics beside Intel or AMD graphics | also `nvidia-prime`: the desktop runs on the integrated graphics, and `prime-run` puts a game on the NVIDIA card |
| NVIDIA graphics older than the GTX 16 and RTX 20 series | nothing more: they run on the open nouveau driver, since NVIDIA's own modules start with those |
| a cellular modem | `modemmanager` |
| a fingerprint reader Nova can drive | `fprintd`, and the offer to enroll a finger |
| an Intel MIPI camera (IPU6 or IPU7), as recent thin laptops have | `libcamera`, `libcamera-ipa` and `pipewire-libcamera`, so apps can use it |

Every computer also gets `linux-firmware`, the sound firmware of recent Intel and AMD laptops, and `linux-lts` as the fallback kernel.

Video is decoded on the card that drives the screen: the integrated one where there is one, and the NVIDIA card where it is the only one or the monitors are plugged into it.

## A sharp display

- **Wayland apps** draw at the display's scale, which Settings → Displays sets.
- **X11 apps** (Steam, JetBrains' IDEs and the like) take a whole-number scale at login: the built-in display's, or the largest display's on a desktop, from 2x up.
- A scale changed in Settings → Displays reaches X11 apps at the next login.
- `hl.env("GDK_SCALE", "2")` in `~/.config/hypr/monitors.lua` sets that scale yourself.

## A laptop other than the P1

Every laptop gets these, the P1 too:

- **Power modes on battery**, through power-profiles-daemon: every unplug starts in Power Saver, a mode you pick lasts until the next plug-in, and plugged in it is always full power.
- **A charge limit**, where the battery has one: a percentage on ThinkPads and most laptops, or the firmware's own fixed limit on Lenovo IdeaPads and Legions. Every limit is read back from the battery after it is set.
- **Sleep that lasts**: a closed lid suspends, and on a computer that can hibernate, 2 hours asleep on battery become hibernation, so a weekend in a bag does not drain it. Plugged in it never hibernates. At the battery's last 2% it hibernates at once.
- **The lid and the power button**, in Settings → Battery: what a closed lid does plugged in, what the button does, and when it hibernates.
- **Battery Life**: the battery's measured runtime and history, rather than a guess.
- **An undervolt** for an Intel CPU, where its firmware lets one through ([power](power.md#undervolting)).

A discrete NVIDIA card sleeps while nothing uses it, where its driver can do that:

- **RTX 30 series and newer:** by itself. Nova allows the card and its sound and USB functions to be suspended, which is the setup NVIDIA's driver asks for.
- **GTX 16 and RTX 20 series:** only when the driver is asked to, which NVIDIA leaves off for them and so does Nova. `nova doctor` gives the one line that turns it on, and how to take it back.
- **A card that drives a display** stays awake, on any laptop.

Settings offers no switch for the card, and `nova doctor` says when it is awake with nothing on it.

The power governor, which sets the CPU's limits and the fans to the load, starts only on the P1 so far. It starts on another model once its tiers are measured there and match the P1's results on the watt meter.

## What the P1 Gen 4i gets

On top of the above:

- **The power governor**, `nova power`: the discrete GPU taken off the PCI bus on battery, the CPU's limits and the integrated GPU's clocks set to the load, and the fans on Nova's own curves. Its [manual](power.md) has the commands and the measurements.
- **A choice for the discrete GPU** in Settings → Performance: On When Plugged In, or Always Off. The menu's Toggle → Discrete GPU switches it by hand, and `nova power run <program>` runs one program on it.
- **Its hardware profile**: its packages, fan control, the NVIDIA and Bluetooth module options, the Wi-Fi power-save setting and a kernel option for waking from sleep.
- **A session tuned for it**: the desktop pinned to the integrated GPU, video decoded there, and direct scanout for fullscreen video.
- **A speaker tuning**, which `nova audio tuning` turns on or off.

[The P1's notes](hardware/thinkpad-p1-gen4i.md) have what was measured on it, and why each choice was made.

## Hardware profiles

A profile is Nova's data for one model, matched by what the firmware reports: the model's name, its maker, or a desktop's mainboard. It can hold:

- packages the installer adds, and `nova update` keeps installed;
- settings that have to live in `/etc`, such as module options, which Nova copies there and removes again when a release drops them;
- a session environment and Hyprland settings, which check the model themselves.

Nova has a profile for the ThinkPad P1 Gen 4i. Another model gets one when someone who has it measures what it needs. A portable Nova takes no profile, since it starts a different computer each time.

## How to tell what your computer has

- **`nova doctor`** names the computer's hardware profile, or says it has none ("the generic setup"), and lists the patches that are on.
- **`nova doctor`** also looks over the parts of any computer, and says what to install or where to look when one is not working:
  - each graphics card and its driver, and NVIDIA's video decoding;
  - on a laptop with two graphics cards, whether the NVIDIA one sleeps when idle;
  - Wi-Fi, sound and an Intel MIPI camera that have no driver or no firmware;
  - firmware the kernel asked for and did not find;
  - Secure Boot, and how the computer sleeps or why it cannot hibernate.
- **Settings → About** shows the computer's model, processor, memory and storage.
- **The installer** says "which Nova knows" when it finds a profile for the computer.
- **Settings → Performance** and **Settings → Battery** show only what the computer has: power modes, a GPU switch, an undervolt, a charge limit.
