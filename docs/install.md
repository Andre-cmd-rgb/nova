# Installing Nova

This page covers making the USB stick, the questions the installer asks, what it sets up, and the three things a stick can do beyond a plain install: carry your files over, install without internet, and hold a portable Nova that starts any PC.

## Before you start

- **A 64-bit PC (x86-64) that starts with UEFI.** A computer that starts the stick in legacy BIOS mode is refused: turn on UEFI boot in its firmware settings.
- **A disk of 64 GiB or more.** Nova takes the whole disk.
- **Secure Boot off**, in the firmware settings. The installer stops before its first question when it is on, and says how to turn it off. If Windows stays on the computer (on another disk) and uses BitLocker or Device Encryption, it asks for its recovery key at its next start once Secure Boot is off: have the key at hand first.
- **A USB stick of 2 GiB or more**, or 32 GB or more for a [portable Nova](#a-portable-nova).
- **The internet**, unless the stick carries every package ([below](#installing-without-internet)). Ethernet connects by itself; the installer asks for Wi-Fi when there is no cable.

The newest [release](https://github.com/Andre-cmd-rgb/nova/releases) has the ISO (`nova-<version>-x86_64.iso`), its `.sha256`, and `nova-usb`. With `nova-usb` you need only it: it fetches the ISO itself.

## Making the stick

### With nova-usb, on an Arch-based system

`nova-usb` writes a stick of its own rather than the bare ISO. It can put every package on it, carry your SSH keys and files, or install Nova itself onto the stick.

1. Install `gum`, which `nova-usb` asks its questions with: `sudo pacman -S gum`. On Nova it is already there, and the command is `nova usb`.
2. Plug the stick in.
3. Run it as yourself, not as root:

   ```sh
   bash nova-usb             # the questions, then the stick
   bash nova-usb --dry-run   # every question, and nothing written
   bash nova-usb --iso <file>   # an ISO you already have, used as it is, with no signature checked
   ```

It downloads the newest release's ISO and checks it against the release's checksum, and the checksum against Nova's signing key. Then it asks, one question a screen; Esc goes back one:

1. **Which stick.** Each is listed with what it holds now, so a backup drive is recognized before it is erased.
2. **What goes on the stick:**
   - **Clean**: only the installer.
   - **Custom**: the installer and things of yours ([carrying your files over](#carrying-your-files-over)).
   - **Portable**: Nova itself, to start any PC from the stick ([a portable Nova](#a-portable-nova)).
3. **What to bring** (Custom and Portable): your SSH keys and the files and folders at the top of your home, each with its size, or something further in, typed by hand.
4. **Every package on the stick too?** (Clean and Custom): yes installs without internet ([below](#installing-without-internet)).
5. **A passphrase** (Custom), 8 characters or more, when you bring something: what you bring is encrypted on the stick.
6. **A summary** of what is erased and what is written, and whether it fits. Type the stick's name to go ahead.

It asks for sudo once, to write. Everything written is read back from the stick and checked before it is done.

### With any USB writer

On any other system, write the ISO as it is with `dd` or any USB writer. That stick installs over the network.

## Starting from the stick

1. Plug the stick in and start the computer.
2. Open its boot menu: F12 at power-on on most computers, F9, F11 or Esc on some.
3. Pick the stick. Its own menu offers:
   - **Install Nova**;
   - **Install Nova (safe graphics)**, the same with the kernel's `nomodeset`, for a screen the first leaves dark;
   - **Memory test (memtest86+)**.

## The questions

The installer asks everything first, one question a screen, and touches no disk until you type `erase`. Esc goes back one question; Ctrl+C stops, with nothing changed. Across the top of each screen are the steps: the ones done ticked (√), this one marked (»), the ones to come dotted (·). On the stick's own console the screens are in Nova's colours, in a font sized to the screen, so the text is the same size on a 1080p and a 4K panel.

1. **Keyboard layout.** A stick made by `nova-usb` offers the layout of the computer it was made on.
2. **The passphrase of what the stick carries**, when it carries something. Enter installs without it.
3. **Wi-Fi**, when there is no cable: pick a network and type its password, name a hidden one, or go on without a network (only a stick with every package installs without one).
4. **Where Nova goes**, only when a USB disk of 32 GB or more is plugged in beside the stick: this computer's disk, or that USB disk ([portable](#a-portable-nova)).
5. **The disk.** Everything on it is erased. Each disk is listed with its size and model, and what it holds now: each partition's label, file system and size, the largest first.
6. **Encryption**: no, or yes with a passphrase at every start ([below](#encryption)).
7. **You**: your full name, a username (suggested from the name), and a password of 8 characters or more, for the lock screen and sudo.
8. **A fingerprint**, when there is a reader Nova can drive: the right index finger, enrolled there and then. Settings → Lock Screen sets it up later too.
9. **This computer**: its name (`nova` unless you type another; `nova-usb` for a portable Nova) and its time zone (type a city).
10. **A summary** of what happens to which disk, the disk that is erased on top. Type `erase` to install.

While it installs, one screen shows the install's parts: each ticked with its time once it is done, the one running with what it does now and its clock, and for the packages a bar, counting them as they download, install and run their hooks. What the commands print goes to the log, not the screen.

When it is done, take the stick out and restart. The computer starts into the lock screen.

## What the installer sets up

| | |
|---|---|
| Disk | a 2 GiB EFI partition and one btrfs partition, with subvolumes for snapshots (`@`, `@home`, `@log`, `@pkg`, `@snapshots`, `@swap`) |
| Swap | a swap file for hibernation, the size of the memory, up to an eighth of the disk |
| Kernel | `linux-nova`, or Arch's `linux` on a CPU without the x86-64-v3 instructions; `linux-lts` as the fallback either way |
| Drivers | the microcode, firmware and graphics drivers this computer needs ([hardware](hardware.md#what-the-installer-picks)) |
| Model | the computer's [hardware profile](hardware.md#hardware-profiles), when Nova has one for it |
| Account | yours, an administrator through sudo; root's password is locked |
| Theme | white; the welcome after your first unlock, and Settings → Appearance, change it |
| Apps | Chrome, VS Code, Claude Code and Codex, when online |
| Log | `/var/log/nova-install.log`, kept on the new system; it ends with a table of how long each step took |

## Encryption

Encryption is off unless you turn it on.

- **Off**: anyone who has the disk can read it.
- **On**: the btrfs partition is LUKS2, and the disk asks for its passphrase at every start, before anything else. Without the passphrase nothing on the disk can be read by anyone, you included.

The EFI partition, which holds the kernels, stays plain, so the firmware can start them. The disk opens with its passphrase, never the TPM.

## Carrying your files over

A **Custom** stick from `nova-usb` brings your SSH keys and the files and folders you pick from your home.

- They travel compressed, on a second partition of the stick (`NOVA-DATA`), encrypted with LUKS2, with a checksum for each.
- The installer asks for the passphrase first. Enter, or Esc, installs without them.
- It checks every archive against its sum. A stick that reads back wrong carries nothing over: all or nothing.
- Your name, username and time zone default to the old computer's, and so does the computer's name when you reinstall the same computer.
- Once your account exists, each item goes back into the new home as it was in the old one.

A stick made by an older `nova-usb` may carry more (a browser, Wi-Fi networks, a package list). That is left on the stick.

## Installing without internet

Answer yes to **Every package on the stick too?** in `nova-usb`. The stick then holds every package any install can need, and installs on any computer with no network.

- Making it needs `pacman` and `fakeroot` on the system that makes it.
- The packages download to that computer before the stick is erased, or straight to the stick when there is no room.
- Chrome, VS Code, Claude Code and Codex need the network: an offline install says so. The welcome after your first unlock joins a Wi-Fi network and then installs Chrome and VS Code; `nova apps install; mise install` adds all four.

## A portable Nova

Nova can live on a USB stick or drive of 32 GB or more, and start any 64-bit PC from it without touching the PC's own disk. Use it to try Nova, to use it on a computer that runs Windows, or to carry your desktop, settings and files from one computer to the next.

### Making one with nova-usb

1. Run `nova-usb` and pick **Portable**.
2. Pick what to bring, as for Custom: your SSH keys and files. They go straight into the new home.
3. Read the summary and type the stick's name. `nova-usb` warns when the stick is on a USB 2 link.
4. The release's own installer asks for your name and password, the stick's name, and whether to encrypt it. Encrypt it: anyone who finds a lost stick can read an unencrypted one.
5. Type `erase`. The packages download as it goes, so it needs the internet.

### Making one without a Linux computer

1. Write the ISO to one stick, with any USB writer.
2. Plug a second stick or drive, of 32 GB or more, in beside it.
3. Start from the first. The installer asks **Where does Nova go?** and offers the USB disk beside it.

### Starting a PC from it

Plug it in and pick it in the PC's boot menu: F12 on most, F9, F11 or Esc on some. Secure Boot has to be off on every PC it starts, as for an install; the PC it is made on may have it on. On a Windows PC with BitLocker or Device Encryption, turning Secure Boot off makes Windows ask for its recovery key at its next start: have the key at hand first.

### How it differs

A portable Nova is the same Nova, made a guest wherever it starts:

- Arch's own kernel, which any 64-bit CPU runs, and an initramfs for every computer rather than one;
- both CPU makers' microcode, and the Intel and AMD graphics drivers;
- NVIDIA cards on the open nouveau driver, since NVIDIA's own would leave older cards with none;
- no hibernation, and no swap file;
- nothing tuned for one model: no hardware profile, no undervolt, no [patches](patches.md), and no fingerprint offered;
- no boot entry written into any PC's firmware, the one it was made on included.

### Speed

It runs as fast as the stick does.

- A fast USB 3 stick, or better an SSD in a USB case, feels like an internal disk.
- A cheap stick is slow at the many small writes a desktop makes.
- Use a USB 3 port, often the blue one.

## When the install stops

- **It says at which step.** The part that stopped is marked on the install's screen, with the error under it, the log's last lines, and where the whole log is: `/var/log/nova-install.log`, kept in memory until the installer restarts.
- **To try again from the start** without a restart, run `nova-install-start`. It keeps the stopped try's log as `nova-install.log.1`.
- **No network, and no packages on the stick:** connect by hand with `iwctl`, then run `nova-install-start` again.
- **A disk in use** by the live system (mounted, swap or LVM) is refused; pick another.
