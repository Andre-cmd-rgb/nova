# Mobile Data

A compact mobile-broadband (WWAN) widget for Nova's bar: one signal glyph next
to the Wi-Fi arc, and a narrow panel with an on/off switch, live throughput,
and a billing-period data counter. Text messages the SIM receives arrive as
desktop notifications.

Everything runs as your normal user through NetworkManager — no root, no polkit
rule, no systemd unit, no daemon of its own.

```
┌─────────────────────────────┐
│ 󰢼  Mobile Data        [ ● ] │
│    VERY · 5G                │
│                             │
│ Signal                 62%  │
│ Ping                  38 ms │
│ Down             1.4 MB/s   │
│ Up                92.0 KB/s │
│ ─────────────────────────── │
│ Used                1.24 GB │
│ Resets               Sep 1  │
└─────────────────────────────┘
```

## Requirements

| Needs | Why |
|---|---|
| NetworkManager (`nmcli`) | owns the `gsm` connection profile that carries the data |
| ModemManager (`mmcli`) | operator, technology, signal quality, SIM and modem state, text messages |
| `rfkill`, `iproute2`, `iputils` | radio state, interface address, the panel's ping |

The installer adds ModemManager when it finds a modem; anywhere else it is
`pacman -S modemmanager`. The widget is in the default bar and stays hidden on
a computer without a modem.

## First run

If you have never used mobile data on this machine, create the connection
profile once:

```bash
nova mobile-data setup            # APN auto-detected from the SIM
nova mobile-data setup iliad      # or name the APN yourself
```

That creates a NetworkManager `gsm` profile called `mobile`, turns autoconnect
on, and gives it route metric 700 — above Nova's Wi-Fi (600), so mobile data
carries traffic only when nothing better has a default route.

Then tell the counter when your plan renews:

```bash
nova mobile-data reset-day 17
```

## Using it

| Where | Action | Result |
|---|---|---|
| Bar glyph | left click | open/close the panel |
| Bar glyph | right click | toggle mobile data |
| Bar glyph | middle click | force a refresh |
| Panel | switch, or `t` | toggle mobile data |
| Panel | `Esc` | close |
| Panel | `Tab` | move to the next bar panel |

The glyph shows signal strength and dims while the modem is powered but not
carrying traffic. It hides itself entirely when the machine has no WWAN
hardware.

Off means off: the switch soft-blocks the radio (`nmcli radio wwan off`) rather
than dropping the connection, because NetworkManager would otherwise
autoconnect straight around a plain disconnect.

## Configuration

Widget settings live on the bar entry in `~/.config/nova/shell.json`:

```json
{ "id": "nova.mobile-data", "interval": 10, "backgroundStats": true }
```

- `interval` — seconds between background polls while the panel is closed
  (default `10`, minimum `2`). An open panel always refreshes every 1.5 s.
- `backgroundStats` — keep throughput and latency sampling while the panel is
  closed (default `true`), so it opens on real numbers. See below for what it
  costs; set it to `false` to sample only while the panel is open.
- `smsNotifications` — announce incoming text messages (default `true`). See
  [Text messages](#text-messages).

Everything else lives in `~/.config/nova-mobile-data/config`, one
`key=value` per line. The file is parsed, never sourced, so nothing in it can
execute:

| Key | Default | Meaning |
|---|---|---|
| `PROFILE` | first `gsm` profile found | NetworkManager profile to drive (`nova mobile-data profile <name>`) |
| `RESET_DAY` | `1` | day of the month the usage counter renews |
| `ROUTE_METRIC` | `700` | metric written by `nova mobile-data setup` |
| `ON_TIMEOUT` | `90` | seconds `on` may spend bringing the modem up |
| `CHECK_TIMEOUT` | `90` | seconds `check` waits for the modem to read its SIM slot |
| `SMS_KEEP` | `200` | messages kept in the local archive |

## More than one mobile profile

If NetworkManager has several `gsm` profiles — one you made yourself and one
`nova mobile-data setup` created, say — decide which is yours and point the plugin
at it:

```bash
nova mobile-data profile very          # drive this one
nova mobile-data setup internet.it     # and give it the right APN
```

Leave only that one on autoconnect, or NetworkManager will pick whichever it
used last and the two will trade the connection between them:

```bash
nmcli connection modify <the-other-one> connection.autoconnect no
```

## CLI

```
nova mobile-data info [--verbose]   key=value status block for the widget
nova mobile-data status             one human-readable line
nova mobile-data on | off | toggle  radio and connection control
nova mobile-data enable | disable   aliases for on and off
nova mobile-data reset              power-cycle a modem that refuses to connect
nova mobile-data check              switch on a modem kept off for want of a SIM,
                                    and look for one again
nova mobile-data setup [APN]        create or refresh the NetworkManager profile
nova mobile-data profile [name]     show or choose the NetworkManager profile
nova mobile-data apn <APN>          change the APN on the profile
nova mobile-data reset-day <1-31>   billing day for the usage counter
nova mobile-data version            print the plugin version

nova mobile-data sms list           messages received, newest first
nova mobile-data sms show <id>      one message in full
nova mobile-data sms poll           file and announce what has arrived
nova mobile-data sms clear          empty the local archive
```

`info` is the widget's data feed; `--verbose` adds byte counters and a
latency sample and is only used while the panel is open.

## Text messages

A SIM that carries data carries text messages too, and they arrive as ordinary
desktop notifications:

```
╭──────────────────────────────╮
│ 󰍡  VERY                      │
│ Hai 1,2 GB residui fino al   │
│ 31/08. Ricarica su very.it   │
╰──────────────────────────────╯
```

The widget runs `nova mobile-data sms poll` on its own slow cadence — the poll
interval, never faster than ten seconds — and that command is the whole
lifecycle of a message: read what the modem is holding, write it to an archive
under `~/.local/state/nova-mobile-data/inbox`, notify, and only then delete
it from the modem. A message is filed before it is deleted, always, and a
delete that fails just leaves it to be picked up next time rather than
announced twice.

```bash
nova mobile-data sms list        # newest first
nova mobile-data sms show 12     # one message in full
nova mobile-data sms clear       # empty the archive
```

**Why it deletes them.** The modem's own store is small — a couple of dozen
slots on a SIM — and a full store is a phone that has stopped receiving: the
network holds new messages back until there is room. Something has to empty
it, so this does, which is why the archive is written first. If you move the
SIM to a phone afterwards, the messages are not on it; they are in the archive
here. The newest `SMS_KEEP` (200) are kept.

**It only hears what the radio hears.** Messages arrive at the modem, so
nothing is delivered while mobile data is off — `off` blocks the radio. They
are not lost: the network holds them and delivers when the radio comes back,
within whatever validity period your operator uses.

Nothing is read while `nova-shell` is not running either, because the widget
is what runs the poll — the plugin still has no daemon. Messages simply sit on
the modem until it starts, and are announced then; a batch of more than three
gets one line rather than three toasts. To pick them up without the shell,
run `nova mobile-data sms poll` from a systemd user timer.

Sending is not part of this. `mmcli --messaging-create-sms` is there if you
want it.

## How the data counter works

NetworkManager does not accumulate usage, and the kernel's per-interface
counters reset whenever the interface goes away. So the plugin keeps a running
total in `~/.local/state/nova-mobile-data/meter`: each poll adds the delta
since the last sample, a counter that moved backwards (or a new interface)
starts a fresh baseline instead of a negative delta, and the total resets to
zero on your renewal day. Two polls can never race each other — the file is
updated under `flock`.

It counts every byte the modem's interface moves, which is what your operator
bills. It is not a substitute for your operator's own figure.

## Latency sampling, and what it costs

Latency is one ICMP echo to `1.1.1.1`, bound to the modem's interface — the
default route is normally Wi-Fi, and an unbound ping would measure the wrong
link entirely. It is sent every 1.5 s while the panel is open, and once per
poll (10 s by default) while it is closed, only ever while the modem is
connected. The plugin makes no other network requests.

The figure shown is the median of the last five samples, not the mean. A mobile
link throws the occasional very slow round trip — a retransmit at low signal, a
radio coming out of a power-saving state — and under a mean a single 900 ms
sample drags the number for the next five ticks, which reads as latency slowly
settling when it is really one outlier passing through. The median absorbs it.

Background sampling is what lets the panel open on numbers that are already
there instead of an empty window filling in front of you. It is not free: an
echo and its reply are about 170 bytes, so at the default 10 s poll it costs
roughly 1.5 MB a day — around 45 MB a month — and it wakes the modem's radio on
that cadence, which a laptop on battery will notice. Set `backgroundStats` to
`false` to sample only while the panel is open.

## Troubleshooting

**The widget is not in the bar.** It hides itself when `rfkill` lists no `wwan`
device and ModemManager sees no modem. Check with `nova mobile-data status` and
`mmcli -L`.

**"No connection profile".** Run `nova mobile-data setup <APN>`.

**"NetworkManager is not managing the modem".** Something else owns it —
usually a leftover `systemd-networkd` or a `NetworkManager.conf` `unmanaged-devices`
rule.

**Mobile data looks off after waking from sleep.** It is not off, and you do
not need to turn it back on — give it about half a minute.

These M.2 modems do not survive a suspend. On resume the kernel logs

```
mhi-pci-generic 0000:08:00.0: failed to resume device: -22
mhi-pci-generic 0000:08:00.0: device recovery started
```

and the driver recovers by re-enumerating the module, which takes roughly
thirty seconds. NetworkManager then autoconnects on its own. The widget shows
this as a pending switch and "Modem starting…" rather than as "No modem", and
polls every two seconds until it is back. Flipping the switch during that
window does not speed anything up — and used to make it slower, by starting a
second activation that cancelled the one NetworkManager had already begun.

If it is still not back after a minute, `nova mobile-data status` will say what the
modem is doing.

**Turning it on takes a while.** Coming back from `off` means a firmware boot
and a fresh network registration; half a minute is ordinary. `on` gives the
whole sequence 90 seconds (`ON_TIMEOUT`), waits for the modem to reach the
network before asking NetworkManager to activate anything, and retries inside
that budget. Whatever it ends up saying is shown in the panel, in the bar's
urgent colour, rather than the switch flicking back with no explanation.

**"the modem refused the connection (Busy)".** An MBIM modem answers every
connect with `Busy` while a data session from the last connection is still open
inside its firmware, which is what cutting the radio out from under a live
connection used to leave behind. `nova mobile-data off` now disconnects and clears
the modem's bearers before blocking the radio, so this should not happen; if a
modem is wedged already, `nova mobile-data reset` power-cycles it.

If even that does not clear it — a scan or registration also coming back `Busy`
is the sign — the firmware needs a harder reset than any of this reaches:

```bash
sudo systemctl restart ModemManager
# still stuck? rebind the driver (use your own PCI address from `mmcli -m any`)
echo 0000:08:00.0 | sudo tee /sys/bus/pci/drivers/mhi-pci-generic/unbind
echo 0000:08:00.0 | sudo tee /sys/bus/pci/drivers/mhi-pci-generic/bind
```

A reboot always works. Some Qualcomm M.2 modems stay powered across the WWAN
rfkill switch, so "turn it off and on again" genuinely cannot reach them.

**No notification for a message you know arrived.** The modem only stores
messages while its radio is on, and only the running shell reads them out.
Check that mobile data is on, that `Notify on incoming text messages` is still
ticked for the widget, and then `nova mobile-data sms poll` by hand — it prints
nothing on success, so follow it with `nova mobile-data sms list`. If the message is
in the archive but no toast appeared, the notification server is the thing to
look at, not this.

**Nothing changed after editing the widget.** `nova-restart-shell` loads new
QML; the bar blinks for a second.

## Removing it

```bash
nova bar remove nova.mobile-data
rm -rf ~/.config/nova-mobile-data ~/.local/state/nova-mobile-data
```

That second path holds the message archive, and it is the only copy — read
anything you want to keep before removing it.

The NetworkManager profile is yours and is left alone. Remove it too with
`nmcli connection delete mobile` if you want it gone.
