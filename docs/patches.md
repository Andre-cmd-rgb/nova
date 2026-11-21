# Patches: fixes for one computer

A patch fixes one computer's own fault: memory with a bad spot, a Bluetooth chip that needs a quirk, a start that hangs without a kernel option.

- It lives in `/etc/nova/patches/<name>`, and is bound to that computer: on another one it does nothing.
- A reinstall keeps it: `nova patch export` saves every patch in one zip, `nova patch add` brings them back.
- It is data, never a program: a `patch` file, notes, and files for `/etc`, each named after the patch, so a patch can add to `/etc` but never replace what is there.

A fix every computer of a model needs belongs in that model's [hardware profile](hardware.md#hardware-profiles); a fix for everyone is a change to Nova; a preference goes in `~/.config`.

## Commands

| Command | Does |
|---|---|
| `nova patch` | list the patches, and whether each is on |
| `nova patch show <name>` | its notes and every file it holds |
| `nova patch add <folder\|zip>...` | add patches (one of the same name is replaced) |
| `nova patch remove <name>...` | remove patches, and what they put in `/etc` |
| `nova patch export [<zip>]` | save them all (`~/nova-patches-<hostname>.zip` by default) |
| `nova patch apply` | apply them again, after editing one under `/etc/nova/patches` |
| `nova patch ram test` | test the memory at the next start and keep its bad spots out of use |
| `nova patch ram <address>...` | keep the memory at these addresses out of use |

Adding, removing and applying ask for the administrator's password every time. `nova doctor` lists the patches that are on, and any that cannot apply.

## Moving patches to a reinstall

1. Before reinstalling: `nova patch export`, and keep the zip off the disk you are about to wipe.
2. After: `nova patch add nova-patches-<hostname>.zip`, then restart.

A patch made for this computer comes back on; one made for another is added but stays off.

## The memory patch

Memory with a bad spot (a cell that always reads 1, or 0) silently corrupts whatever lands there. New memory is the fix; until then Nova can keep the bad spots out of use:

```sh
nova patch ram test     # then restart: the kernel tests the free memory, up to a minute longer
nova patch              # after the restart: what the test found
```

The test writes four patterns to the memory the kernel is not using and reads them back; a service then writes one `memmap=` option per bad page, and from the next start the kernel never uses those pages. A test again later adds what it finds. More than 16 places or 64 MiB is too widespread for this to help, and the patch adds nothing. Spots another test found (memtest86+, on the Nova stick's boot menu) can be added by hand: `nova patch ram 0x1d4e1a000-0x1d4e1bfff`.

It cannot cover the ~100 MB the kernel itself occupies during the test (a second test covers more), and any `memmap=` turns off the random placement of the kernel in physical memory, a small loss of hardening.

## Making a patch

For a person, or an AI agent, fixing one computer's fault, on that computer:

1. **Find the fault and show it**: `journalctl -b -p warning`, `journalctl -k`, `lspci -nnk`, `lsusb`, `nova doctor`. Note the line that names it.
2. **Make sure it belongs in a patch**, not in the model's profile or in Nova itself.
3. **Find the smallest fix that is configuration**, preferably one the driver's documentation names, and try it once by hand.
4. **Write the folder**, say `~/nova-patches/<name>/` (the name in lowercase letters, digits and dashes, up to 32): a `patch` file with `description=` (one line) and `machine=this` (`add` writes this computer's ID in its place; `any` is for the rare fix right on every computer); a `README.md` with the fault, the evidence, the fix and how to check it; and the files under `etc/`, each named `NN-nova-patch-<name>.<ext>`.
5. **Add it** (`nova patch add ~/nova-patches/<name>`), restart, and **check** the fault is gone with the same evidence.
6. **Export** with `nova patch export`.

Never edit `/etc` by hand for one computer's fault: a reinstall loses it.

| To fix it with | The file under `etc/` |
|---|---|
| a kernel option | `limine-entry-tool.d/85-nova-patch-<name>.conf`: `KERNEL_CMDLINE[default]+=" option=value"` |
| a module option, or a module kept from loading | `modprobe.d/90-nova-patch-<name>.conf`: `options btusb enable_autosuspend=0`, or `blacklist <module>` |
| a udev rule | `udev/rules.d/90-nova-patch-<name>.rules` |
| a kernel setting | `sysctl.d/90-nova-patch-<name>.conf` |
| a change to a service | `systemd/system/<unit>.d/90-nova-patch-<name>.conf` |
| a command at each start | `systemd/system/nova-patch-<name>.service`, and `systemd/system/multi-user.target.d/nova-patch-<name>.conf` with `[Unit]` and `Wants=nova-patch-<name>.service` |
| NetworkManager, WirePlumber | `NetworkManager/conf.d/90-nova-patch-<name>.conf`, `wireplumber/wireplumber.conf.d/90-nova-patch-<name>.conf` |

A change to the kernel's options, modules or initramfs rebuilds the boot entries (about a minute); everything takes full effect at the next start. File rules: plain files only, at most 64 KiB each and 64 per patch, names of letters, digits and `._@+-`, nothing under `/etc/nova`.

### Example: Bluetooth lost after sleep

`journalctl -k` shows `Bluetooth: hci0: command 0x0c03 tx timeout` after each resume, and turning off the adapter's USB autosuspend keeps it alive:

```
~/nova-patches/bluetooth/patch
    description=Turns off Bluetooth autosuspend, which loses the adapter after sleep
    machine=this

~/nova-patches/bluetooth/etc/modprobe.d/90-nova-patch-bluetooth.conf
    # This computer's Intel AX201 drops off the bus when autosuspended.
    options btusb enable_autosuspend=0
```

Then `nova patch add ~/nova-patches/bluetooth`, restart, check `journalctl -k -b | grep hci0` stays clean after a resume, and `nova patch export`.
