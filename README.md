# Mobile Data

A compact mobile-broadband (WWAN) widget for the [Omarchy](https://omarchy.org)
shell bar: one signal glyph next to the Wi-Fi arc, and a narrow panel with an
on/off switch, live throughput, and a billing-period data counter.

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
| Omarchy 4.0 or newer | the plugin host (`omarchy-shell`) and its `Ui` components |
| NetworkManager (`nmcli`) | owns the `gsm` connection profile that carries the data |
| ModemManager (`mmcli`) | operator, technology, signal quality, SIM and modem state |
| `rfkill`, `iproute2`, `iputils` | radio state, interface address, the panel's ping |

All four ship with a standard Omarchy install. The glyphs come from the Nerd
Font Omarchy already uses for the bar.

## Install

```bash
omarchy plugin add https://github.com/Andre-cmd-rgb/omarchy-mobile-data.git --enable
```

Plugins run unsandboxed inside your shell process — read the code first; it is
one QML file and one bash script.

To install by hand instead:

```bash
git clone https://github.com/Andre-cmd-rgb/omarchy-mobile-data.git \
  ~/.config/omarchy/plugins/andrecmdrgb.mobile-data
omarchy-shell shell rescanPlugins
omarchy plugin enable andrecmdrgb.mobile-data
```

Optionally put the CLI on your `PATH`:

```bash
ln -sf ~/.config/omarchy/plugins/andrecmdrgb.mobile-data/bin/mobile-data \
  ~/.local/bin/mobile-data
```

## First run

If you have never used mobile data on this machine, create the connection
profile once:

```bash
mobile-data setup            # APN auto-detected from the SIM
mobile-data setup iliad      # or name the APN yourself
```

That creates a NetworkManager `gsm` profile called `mobile`, turns autoconnect
on, and gives it route metric 700 — above Omarchy's Wi-Fi (600), so mobile data
carries traffic only when nothing better has a default route.

Then tell the counter when your plan renews:

```bash
mobile-data reset-day 17
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

Widget settings live on the bar entry in `~/.config/omarchy/shell.json`:

```json
{ "id": "andrecmdrgb.mobile-data", "interval": 10, "backgroundStats": true }
```

- `interval` — seconds between background polls while the panel is closed
  (default `10`, minimum `2`). An open panel always refreshes every 1.5 s.
- `backgroundStats` — keep throughput and latency sampling while the panel is
  closed (default `true`), so it opens on real numbers. See below for what it
  costs; set it to `false` to sample only while the panel is open.

Everything else lives in `~/.config/omarchy-mobile-data/config`, one
`key=value` per line. The file is parsed, never sourced, so nothing in it can
execute:

| Key | Default | Meaning |
|---|---|---|
| `PROFILE` | first `gsm` profile found | NetworkManager profile to drive |
| `RESET_DAY` | `1` | day of the month the usage counter renews |
| `ROUTE_METRIC` | `700` | metric written by `mobile-data setup` |
| `ON_TIMEOUT` | `90` | seconds `on` may spend bringing the modem up |

## CLI

```
mobile-data info [--verbose]   key=value status block for the widget
mobile-data status             one human-readable line
mobile-data on | off | toggle  radio and connection control
mobile-data enable | disable   aliases for on and off
mobile-data reset              power-cycle a modem that refuses to connect
mobile-data setup [APN]        create or refresh the NetworkManager profile
mobile-data apn <APN>          change the APN on the profile
mobile-data reset-day <1-31>   billing day for the usage counter
mobile-data version            print the plugin version
```

`info` is the widget's data feed; `--verbose` adds byte counters and a
latency sample and is only used while the panel is open.

## How the data counter works

NetworkManager does not accumulate usage, and the kernel's per-interface
counters reset whenever the interface goes away. So the plugin keeps a running
total in `~/.local/state/omarchy-mobile-data/meter`: each poll adds the delta
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
device and ModemManager sees no modem. Check with `mobile-data status` and
`mmcli -L`.

**"No connection profile".** Run `mobile-data setup <APN>`.

**"NetworkManager is not managing the modem".** Something else owns it —
usually a leftover `systemd-networkd` or a `NetworkManager.conf` `unmanaged-devices`
rule.

**Turning it on takes a while.** Coming back from `off` means a firmware boot
and a fresh network registration; half a minute is ordinary. `on` gives the
whole sequence 90 seconds (`ON_TIMEOUT`), waits for the modem to reach the
network before asking NetworkManager to activate anything, and retries inside
that budget. Whatever it ends up saying is shown in the panel, in the bar's
urgent colour, rather than the switch flicking back with no explanation.

**"the modem refused the connection (Busy)".** An MBIM modem answers every
connect with `Busy` while a data session from the last connection is still open
inside its firmware, which is what cutting the radio out from under a live
connection used to leave behind. `mobile-data off` now disconnects and clears
the modem's bearers before blocking the radio, so this should not happen; if a
modem is wedged already, `mobile-data reset` power-cycles it.

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

**Nothing changed after editing the plugin.** `omarchy-shell shell rescanPlugins`.

## Uninstall

```bash
omarchy plugin remove andrecmdrgb.mobile-data
rm -f ~/.local/bin/mobile-data
rm -rf ~/.config/omarchy-mobile-data ~/.local/state/omarchy-mobile-data
```

The NetworkManager profile is yours and is left alone. Remove it too with
`nmcli connection delete mobile` if you want it gone.

## License

MIT — see [LICENSE](LICENSE).
