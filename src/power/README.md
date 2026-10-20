# Power manager: ThinkPad P1 Gen 4i

`thinkpad-power` is the AC/battery policy: the discrete GPU off the PCI bus on
battery, CPU and platform tunables, Wi-Fi power save, and the hibernate rescan.
`thinkpad-powerd` is the load-adaptive governor that owns PL1, PL2, the
frequency ceiling, the iGPU ceiling and the fans while it runs.

Both ship in the `nova` package for every machine and only ever start on a
P1 Gen 4i. How they are wired, and the facts behind every choice, are in
[docs/hardware/thinkpad-p1-gen4i.md](../../docs/hardware/thinkpad-p1-gen4i.md);
the full manual (commands, tunables, the governor) is
[docs/hardware/thinkpad-power-manual.md](../../docs/hardware/thinkpad-power-manual.md).

```
nova power gpu                 turn the discrete GPU on or off
nova power gpu mode off        keep it off plugged in too (Settings, Battery); auto undoes it
nova power gpu status -v       what holds it, and everything else worth knowing
nova power gpu run <program>   one program on the discrete GPU
sudo thinkpad-power doctor     what keeps the machine out of deep package states
sudo thinkpad-power boost 60   lift the battery CPU caps for an hour
```

| | |
|---|---|
| `bin/thinkpad-power` | the policy |
| `daemon/` | the governor; std only, built by the workspace at the repository root |
| `systemd/`, `udev/` | units, the sleep hook and the plug rule, each DMI-guarded |
| `test/roundtrip.sh` | the policy's library half against fixtures; part of `make test` |
| `test/watts.sh` | the measuring stick: average draw on battery over N seconds |
