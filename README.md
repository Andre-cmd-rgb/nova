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
{ "id": "andrecmdrgb.mobile-data", "interval": 10 }
```

- `interval` — seconds between background polls while the panel is closed
  (default `10`, minimum `2`). An open panel always refreshes every 1.5 s.

Everything else lives in `~/.config/omarchy-mobile-data/config`, one
`key=value` per line. The file is parsed, never sourced, so nothing in it can
execute:

| Key | Default | Meaning |
|---|---|---|
| `PROFILE` | first `gsm` profile found | NetworkManager profile to drive |
| `RESET_DAY` | `1` | day of the month the usage counter renews |
| `ROUTE_METRIC` | `700` | metric written by `mobile-data setup` |

## CLI

```
mobile-data info [--verbose]   key=value status block for the widget
mobile-data status             one human-readable line
mobile-data on | off | toggle  radio and connection control
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

## Privacy

While the panel is open it sends one ICMP echo per 1.5 s to `1.1.1.1`, bound to
the modem's interface, to measure latency on that link specifically. Nothing is
sent anywhere while the panel is closed, and the plugin makes no other network
requests.

## Troubleshooting

**The widget is not in the bar.** It hides itself when `rfkill` lists no `wwan`
device and ModemManager sees no modem. Check with `mobile-data status` and
`mmcli -L`.

**"No connection profile".** Run `mobile-data setup <APN>`.

**"NetworkManager is not managing the modem".** Something else owns it —
usually a leftover `systemd-networkd` or a `NetworkManager.conf` `unmanaged-devices`
rule.

**The switch turns itself back off.** The modem re-enumerates when the radio
comes back and can take fifteen seconds or so; the switch stays busy until
NetworkManager reports the device again, then gives up after 25 s.

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
