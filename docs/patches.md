# Patches: fixes for one computer

A patch fixes one computer's fault. Examples are memory with a bad spot, a
Bluetooth chip that needs a quirk, or a start that hangs without a kernel
option. It lives in `/etc/nova/patches/<name>`. It is bound to that computer,
so the same patch does nothing on another one. A reinstall keeps it too:
`nova patch export` puts every patch in one zip, and `nova patch add` brings
them back after the reinstall.

A patch is the wrong place for:

- **A fix every computer of a model needs**, such as a ThinkPad P1 Gen 4i
  setting. That goes in the model's hardware profile (`data/hardware/`), which
  Nova applies on every computer of that model.
- **A fix for everyone.** That is a change to Nova itself.
- **A preference.** That goes in `~/.config`.

A patch is data, never a program. It has a `patch` file that says what it does
and which computer it is for, notes for whoever reads it next, and the files it
puts in `/etc`. Each of those files is named after the patch, so a patch can
add files to `/etc` but cannot replace any file already there.

## Commands

| Command | What it does |
|---|---|
| `nova patch` | Lists the patches here and says whether each is on. |
| `nova patch show <name>` | Shows what one does: its notes and every file it holds. |
| `nova patch add <folder\|zip>...` | Adds patches, from a folder made by hand or a zip from `export`. A patch with the same name is replaced. |
| `nova patch remove <name>...` | Removes patches, along with what they put in `/etc`. |
| `nova patch export [<zip>]` | Saves all of them in one zip (by default `~/nova-patches-<hostname>.zip`). |
| `nova patch apply` | Applies them again, after you edit one by hand under `/etc/nova/patches`. |
| `nova patch ram test` | Tests the memory at the next start and keeps the bad spots it finds out of use (see below). |
| `nova patch ram <address>...` | Keeps the memory at these addresses out of use. |

Adding, removing and applying ask for the administrator's password every
time. A patch's files can do anything root can, so a password typed a moment
earlier does not count. `nova doctor` lists the patches that are on, and warns
about any that cannot apply.

## What a patch is made of

```
bluetooth/
├── patch                                   what it does, and which computer it is for
├── README.md                               the notes: the fault, the evidence, how to check the fix
└── etc/
    └── modprobe.d/
        └── 90-nova-patch-bluetooth.conf    goes to /etc/modprobe.d/90-nova-patch-bluetooth.conf
```

- **The folder's name** is the patch's name: lowercase letters, digits and
  dashes, up to 32 characters, such as `bluetooth` or `ram`.
- **`patch`** holds `key=value` lines. Other lines are ignored.
  - `description=` is required: one line saying what the patch does, such as
    `Turns off Bluetooth autosuspend, which loses the adapter after sleep`.
  - `machine=` is required: `this`, `any`, or a computer's ID.
    - `this` means the computer the patch is added on. `nova patch add` writes
      this computer's ID in its place.
    - `any` is for a fix that is right on every computer you install Nova on,
      which is rare.
    - The ID is a digest of the computer's serial numbers, which a reinstall
      does not change. Only root can read those serials, so write `this` and
      let `add` fill in the ID.
- **`README.md`** is optional but expected. It should cover what was wrong, how
  you know (the log line, the test), what the fix does, and how to check it
  worked.
- **`etc/`** is a tree that is copied into `/etc`.
  - It may hold only plain files: no links or devices.
  - Every file's name must contain `nova-patch-<name>`.
  - Names use letters, digits and `._@+-` only.
  - Each file is at most 64 KiB, and a patch has at most 64 files.
  - Nothing may go under `/etc/nova`.

What happens when a patch is applied:

- Its files are installed with mode 0644, owned by root.
- A file another patch also brings, or one already in `/etc` that no patch
  put there, is never replaced. The patch stays off and `nova patch` says why.
- `/var/lib/nova/patch-files` lists every file the patches put in `/etc`. When
  a patch changes or is removed, Nova takes out the files it no longer has.
- A change to the kernel's command line (`limine-entry-tool.d`), to module
  options (`modprobe.d`) or to the initramfs (`mkinitcpio.conf.d`) rebuilds
  the boot entries, which takes about a minute.
- A change to systemd files reloads systemd, and a change to udev rules
  reloads udev.
- Everything takes full effect at the next start.

A portable Nova (`nova-install --portable`) takes no patches. It starts a
different computer each time, and a patch is for one.

## Moving patches to a reinstall

1. Before reinstalling, run `nova patch export`. Keep the zip off the disk you
   are about to wipe.
2. After reinstalling, run `nova patch add nova-patches-<hostname>.zip`, then
   restart.

A patch made for this computer comes back on. A patch made for another
computer is added but stays off, and `nova patch` says so. Patches made
`any` apply everywhere.

## The memory patch

Some memory has a bad spot: a cell that always reads back 1, or always 0,
whatever is written to it. Any program, file or page of the kernel that lands
there is silently corrupted. New memory is the full fix. Until then, Nova can
keep the bad spots out of use.

```
nova patch ram test     # then restart
nova patch              # after the restart: what the test found
```

How it works:

1. `nova patch ram test` adds `memtest=4` to the next start's kernel command
   line.
2. At that start, the kernel writes four patterns (all 0s, all 1s, 0101…,
   1010…) to all the memory it is not using, and reads each back. This catches
   a bit stuck at 0 or at 1. The screen stays dark for up to a minute longer
   than usual. It has to be a restart: waking from sleep or hibernation does
   not run the test.
3. The kernel sets aside every bad spot it finds, for that start, and logs
   each one.
4. `nova-patch-ram.service` then reads the log and writes the patch. It holds
   one `memmap=<size>$<address>` per bad spot, each spot rounded out to its
   4 KiB page. The service also takes the test off the command line and
   rebuilds the boot entries.
5. From the next start on, the kernel keeps those pages out of use from the
   moment it starts.

`nova patch` then reports what the test found:

- the bad spots it found;
- that it found nothing; or
- that it found too many.

A test again later keeps the spots already found and adds new ones. Spots
within 1 MiB of each other are joined into one range.

**Too many** means more than 16 separate places, or more than 64 MiB of bad
memory. The memory is then failing too widely for this to help, and the patch
adds nothing. The same happens when the kernel's log lost some of the lines,
which happens with thousands of bad spots. The patch checks the spots it read
against the total the kernel reports (`EarlyMemtestBad` in `/proc/meminfo`).

**Spots another test found** can be added by hand, such as those from
memtest86+, which the Nova USB stick's boot menu has:

```
nova patch ram 0x1d4e1a008                 # one address, in hex
nova patch ram 0x1d4e1a000-0x1d4e1bfff     # a range
```

**What it cannot do:**

- The test covers the memory free at that start. It cannot cover the
  ~100 MB that the kernel and its initramfs occupy, which is a different place
  each start, so a second test covers more.
- The firmware and the boot loader run before the kernel and know nothing of
  the spots. Rarely, they may put something on one for a single start.
- Any `memmap=` option turns off the random placement of the kernel in
  physical memory. Its place in virtual memory stays random. This is a small
  loss of hardening, and the price of the kernel never landing on a bad spot.

The patch carries this computer's ID, because the spots belong to this
computer's memory. If you move the memory to another computer, test it there.

## Making a patch: the recipe

These steps are for a person or an AI agent fixing one computer's fault. Work
on that computer itself.

1. **Find the fault, and show it.** Use the journal (`journalctl -b -p warning`,
   `journalctl -k`), `dmesg`, `lsusb`/`lspci -nnk`, `rfkill`, or
   `nova doctor`. Find the line that names the fault, and the device's IDs.
2. **Make sure it belongs in a patch.** If every computer of this model has the
   fault, it belongs in the model's hardware profile instead. If it is a bug in
   Nova, Nova needs fixing. A patch is for this one computer.
3. **Find the smallest fix that is configuration**: a kernel option, a module
   option, a udev rule, a sysctl, or a systemd drop-in. Prefer the fix the
   driver's documentation or the kernel's names. Try it once by hand, for
   example with a kernel option typed at the boot menu or `modprobe` with the
   option, before you write it down.
4. **Write the folder.** Put it anywhere you can write, such as
   `~/nova-patches/<name>`, with `patch`, `README.md` and the `etc/` files from
   the table below. Write `machine=this`, and name every file `NN-nova-patch-<name>.<ext>`.
5. **Add it**, with `nova patch add ~/nova-patches/<name>`, and restart.
6. **Check the fault is gone**, with the same evidence as in step 1. Record the
   result in `README.md`, then run `nova patch add` again so the copy in
   `/etc/nova/patches` has it.
7. **Export**, with `nova patch export`, and keep the zip somewhere a reinstall
   will not wipe.

An agent never edits `/etc` directly for a computer's fault, since a reinstall
loses an edit made that way. It never puts one computer's fix into a hardware
profile either.

| To fix it with | The file under `etc/` | Takes effect |
|---|---|---|
| A kernel option | `limine-entry-tool.d/85-nova-patch-<name>.conf`: `KERNEL_CMDLINE[default]+=" option=value"` (no `#` after it on the line) | at the next start; the boot entries are rebuilt |
| A module option, or a module kept from loading | `modprobe.d/90-nova-patch-<name>.conf`: `options btusb enable_autosuspend=0`, or `blacklist <module>` | at the next start; the initramfs is rebuilt |
| A udev rule (a device's power, its wakeup, a quirk) | `udev/rules.d/90-nova-patch-<name>.rules` | at the device's next event, or the next start |
| A kernel setting | `sysctl.d/90-nova-patch-<name>.conf` | at the next start |
| A change to a service | `systemd/system/<unit>.d/90-nova-patch-<name>.conf` | at the next start |
| A command at each start | `systemd/system/nova-patch-<name>.service`, plus `systemd/system/multi-user.target.d/nova-patch-<name>.conf` with `[Unit]` and `Wants=nova-patch-<name>.service` | at the next start |
| NetworkManager, WirePlumber | `NetworkManager/conf.d/90-nova-patch-<name>.conf`, `wireplumber/wireplumber.conf.d/90-nova-patch-<name>.conf` | at the next start |

### Example: Bluetooth lost after sleep

The adapter vanishes after a resume, and `journalctl -k` shows
`Bluetooth: hci0: command 0x0c03 tx timeout` each time. Turning off the
adapter's USB autosuspend keeps it alive. The fix is this patch:

`~/nova-patches/bluetooth/patch`:

```
description=Turns off Bluetooth autosuspend, which loses the adapter after sleep
machine=this
```

`~/nova-patches/bluetooth/etc/modprobe.d/90-nova-patch-bluetooth.conf`:

```
# This computer's Intel AX201 drops off the bus when autosuspended (hci0 tx
# timeouts after each resume).
options btusb enable_autosuspend=0
```

`~/nova-patches/bluetooth/README.md` explains the same: the fault, the log
line, the fix, and that `journalctl -k -b | grep hci0` stays clean after a
resume.

Then run `nova patch add ~/nova-patches/bluetooth`, restart, and run
`nova patch export`.

### Example: a start that needs a kernel option

`etc/limine-entry-tool.d/85-nova-patch-nvme.conf`:

```
# This computer's NVMe drive drops off after its deepest power state.
KERNEL_CMDLINE[default]+=" nvme_core.default_ps_max_latency_us=5500"
```
