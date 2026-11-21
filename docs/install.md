# Installing Nova

Make a USB stick, start the computer from it, answer a few questions. The stick carries every package, so no internet is needed.

## Before you start

- **A 64-bit PC (x86-64) that starts with UEFI**, and **a disk of 64 GiB or more**, which Nova takes whole.
- **Secure Boot off** in the firmware settings. The installer stops and says how when it is on. If Windows stays on another disk and uses BitLocker or Device Encryption, have its recovery key at hand: it asks for it once Secure Boot is off.
- **A USB stick of 4 GB or more** (32 GB for a [portable Nova](#a-portable-nova)).

The newest [release](https://github.com/Andre-cmd-rgb/nova/releases) has `nova-usb`, the ISO's checksum, and a link to the ISO itself (about 3 GB).

## Making the stick

**On an Arch-based system**, use `nova-usb`. It downloads the ISO, checks it against Nova's signing key, writes the stick and reads it back.

```sh
sudo pacman -S gum          # the screens nova-usb asks with (on Nova: nova usb)
bash nova-usb               # the questions, then the stick
bash nova-usb --dry-run     # every question, nothing written
```

It asks which stick (each listed with what it holds now), then what goes on it:

- **Clean**: the installer alone.
- **Custom**: the installer and your SSH keys and files, encrypted with a passphrase ([carrying files over](#carrying-your-files-over)).
- **Portable**: Nova itself, to start any PC from ([a portable Nova](#a-portable-nova)).

**On any other system**, check the ISO (`sha256sum -c nova-<version>-x86_64.iso.sha256`) and write it with any USB writer or `dd`.

## Installing

1. Plug the stick in and open the computer's boot menu: F12 at power-on on most computers, F9, F11 or Esc on some. Pick the stick, then **Install Nova** (**safe graphics** if the screen stays dark; **Memory test** is there too).
2. Answer the questions, one a screen. Esc goes back; Ctrl+C stops with nothing changed:
   - the keyboard layout;
   - Wi-Fi, when there is no cable (optional: Nova installs from the stick either way);
   - where Nova goes, when a USB disk of 32 GB or more is plugged in beside the stick;
   - the disk (everything on it is erased), each listed with what it holds now;
   - encryption: off, or a passphrase at every start;
   - your name, username and password;
   - a fingerprint, where there is a reader;
   - the computer's name and time zone;
   - the default browser: Supernova (Nova's own), Firefox or Chrome.
3. Read the summary and type `erase`. Nothing touches the disk before that.
4. When it is done, take the stick out and restart. The computer starts into the lock screen.

## What you get

| | |
|---|---|
| Disk | a 2 GiB EFI partition and a btrfs one, with subvolumes for snapshots |
| Kernel | `linux-nova` (Arch's `linux` on a CPU older than x86-64-v3), and `linux-lts` as a fallback |
| Drivers | the microcode, firmware and graphics drivers this computer needs ([hardware](hardware.md#what-the-installer-picks)) |
| Swap | a swap file the size of the memory, for hibernation |
| Account | yours, an administrator through sudo; root's password is locked |
| Apps | Supernova, or the browser you chose; VS Code, Claude Code and Codex when online |
| Log | `/var/log/nova-install.log`, with how long each step took |

**Encryption** makes the btrfs partition LUKS2: the disk asks for its passphrase at every start, and without it nothing on the disk can be read, by anyone. The EFI partition stays plain so the firmware can start the kernel. The TPM is never used.

**Offline**, everything installs from the stick except what has to come from the network: VS Code, the coding agents, and Chrome if chosen. The welcome after the first unlock offers them once you are online; `nova apps install` does the same.

## Carrying your files over

A **Custom** stick brings your SSH keys and the files and folders you picked, compressed and encrypted on a second partition of the stick. The installer asks for its passphrase first (Enter skips it), checks every archive, and puts each item back in the new home once your account exists. Your name, username and time zone default to the old computer's.

## A portable Nova

Nova can live on a USB drive of 32 GB or more and start any 64-bit PC without touching its disk: to try Nova, or carry your desktop between computers.

- Make one with `nova-usb` → **Portable**, or write the ISO to one stick, plug a second drive in beside it, start from the first, and pick the drive at **Where does Nova go?**
- Encrypt it: anyone who finds a lost drive can read an unencrypted one.
- Start a PC from it through its boot menu, with Secure Boot off.
- It is made to be a guest: Arch's generic kernel, drivers for every common GPU (NVIDIA on nouveau), no hibernation, no hardware profile or [patches](patches.md), and no boot entry written into any PC's firmware.
- It runs as fast as the drive: an SSD in a USB 3 case feels like an internal disk, a cheap stick does not.

## When the install stops

- The screen says which step stopped, with the error and the end of the log (`/var/log/nova-install.log`, in memory until a restart).
- `nova-install-start` tries again from the start, without a restart.
- A disk in use by the live system (mounted, swap or LVM) is refused: pick another.
