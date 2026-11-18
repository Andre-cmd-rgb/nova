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

The installer looks at the CPU, the graphics, a fingerprint reader and the camera, and adds what they need:

| Your computer has | Nova installs |
|---|---|
| an Intel CPU, an AMD CPU | its microcode (`intel-ucode`, `amd-ucode`) |
| Intel graphics | `intel-media-driver`, `vulkan-intel` |
| AMD graphics | `vulkan-radeon`; Mesa has AMD's video driver built in |
| NVIDIA graphics, GTX 16 or RTX 20 series and newer | NVIDIA's open modules, for the main kernel and the fallback, `nvidia-utils`, and `libva-nvidia-driver`, so the card can decode video |
| NVIDIA graphics beside Intel or AMD graphics | also `nvidia-prime`: the desktop runs on the integrated graphics, and `prime-run` puts a game on the NVIDIA card |
| NVIDIA graphics older than the GTX 16 and RTX 20 series | nothing more: they run on the open nouveau driver, since NVIDIA's own modules start with those |
| a fingerprint reader Nova can drive | `fprintd`, and the offer to enroll a finger |
| an Intel MIPI camera (IPU6 or IPU7), as recent thin laptops have | `libcamera`, `libcamera-ipa` and `pipewire-libcamera`, so apps can use it |

Every computer also gets `linux-firmware`, the sound firmware of recent Intel and AMD laptops, and `linux-lts` as the fallback kernel.

### A cellular modem

Mobile data comes with Nova: ModemManager is part of every install, and is turned on where there is a modem.

- **Its maker's lock.** Many laptop modems are locked by their maker (an FCC lock) until something unlocks them, and until then cannot be turned on at all. ModemManager has an unlock for the modems it knows, and turns on none by itself; Nova turns on every one it has, in `/usr/lib/ModemManager/fcc-unlock.d`. An unlock of your own in `/etc/ModemManager/fcc-unlock.d` goes first.
- **A modem none of them unlocks**, some newer ones in Lenovo laptops among them, needs its maker's own unlock script, which Nova does not ship: `nova doctor` says so, and names Lenovo's. Put the script in `/etc/ModemManager/fcc-unlock.d`, named by the modem's vid:pid, and not in `/usr/lib`, whose names belong to Nova's package.
- **The rest is a switch**: Mobile Data in the bar and in Settings. The first time, it sets mobile data up with the APN for the SIM, and asks for one only if the network turns that down.

Video is decoded on the card that drives the screen: the integrated one where there is one, and the NVIDIA card where it is the only one or the monitors are plugged into it.

## A sharp display

- **Wayland apps** draw at the display's scale, which Settings → Displays sets.
- **X11 apps**, through XWayland (JetBrains' IDEs, a Flatpak without Wayland), scale themselves, by one whole number for every display, as one X server serves them all: the largest display's scale, rounded up (2 for a 1.5x monitor). Nova tells XWayland that scale, as GNOME and KDE do: GTK apps read it from XSETTINGS, Chrome and Electron apps through GTK, Qt, SDL and JetBrains' IDEs from `Xft.dpi`, and other Java apps from `J2D_UISCALE`, set at login.
- **The same size on every display.** Nova's Hyprland draws X11 apps 1:1 on a display of that scale, sharp, and shrinks them to the size of a display of a lower one (`xwayland:scale`, a patch of Nova's, `packaging/hyprland`): beside a 2x panel, an X11 app is as large on a 1x or 1.5x monitor as Wayland apps are there, a little softer, and never enlarged and blurry.
- **Full screen on a display of a lower scale**, an X11 app draws more pixels than the display has, which are then shrunk: 4 times a 1x monitor's beside a 2x panel, a cost an X11 game shows.
- **When the scale changes**, in Settings → Displays, with the scale keys, or as a display comes or goes, GTK apps follow at once, and every X11 app started after it takes the new one. X11 windows keep their size on the screen; a Qt, Chrome or Electron app open through the change may need a restart to be drawn at the new scale.
- **With Arch's Hyprland** (for a release whose Hyprland the patch is not moved onto yet, or until the next login after the update that brought Nova's), each display shows X11 apps at its own resolution: the scale is then the built-in display's while it is on, else the largest display's, to the nearest, and beside the 2x panel an X11 app on a 1x monitor is twice its size there.
- `hl.env("NOVA_X11_SCALE", "1")` in `~/.config/hypr/monitors.lua` sets the scale yourself, from the next login.
- A `GDK_SCALE` you set turns this off: GTK, Chrome and Java follow it, and Qt apps stay at 1x. GTK would take it over XWayland's scale, and draw its text twice as large.
- Apps that read none of these stay sharp but small: Wine (it has its own DPI, in `winecfg`), old Motif and Tk apps, and games that ignore the scale SDL reports. A Qt 5 app that does not turn on Qt's own scaling gets text of the right size, with its icons and spacing at 1x.
- An app's own scale setting multiplies Nova's: a `QT_SCALE_FACTOR=2` set for a Qt app draws it at 4x.

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

Off the P1, Settings offers no switch for the card, and `nova doctor` says when it is awake with nothing on it.

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
