# Nova's power governor

`nova power` is one system with two halves. `nova-power` is the AC/battery
policy: the discrete GPU off the PCI bus on battery, CPU and platform
tunables, Wi-Fi power save, and the hibernate rescan. `nova-powerd` is the
load-adaptive governor that owns PL1, PL2, the frequency ceiling, the iGPU
ceiling and the fans while it runs.

Both ship in the `nova` package for every machine. Their tiers and limits are
measured on the ThinkPad P1 Gen 4i, so for now they start only there. The
manual (commands, tunables, the governor) is [docs/power.md](../../docs/power.md);
how they are wired on the P1, and the facts behind every choice, are in
[docs/hardware/thinkpad-p1-gen4i.md](../../docs/hardware/thinkpad-p1-gen4i.md).

```
nova power                     what the governor is doing: power source, GPU, draw
nova power status -v           and the limits, the fans, runtime PM, ASPM, Wi-Fi
nova power gpu                 turn the discrete GPU on or off
nova power gpu mode off        keep it off plugged in too (Settings, Performance); auto undoes it
nova power gpu run <program>   one program on the discrete GPU
nova power undervolt           the CPU's voltage offset (any Intel laptop that allows one)
nova power lid lock            plugged in, a closed lid locks and the computer keeps running
nova power button sleep        the power button sleeps (or menu, the default, or off)
nova power hibernate 4h        asleep on battery, hibernate after four hours (or never)
sudo nova power doctor         what keeps the machine out of deep package states
sudo nova power boost 60       lift the battery CPU caps for an hour
```

| | |
|---|---|
| `bin/nova-power` | the policy |
| `daemon/` | the governor; std only, built by the workspace at the repository root |
| `systemd/`, `udev/` | units, the sleep hook and the plug rule, each DMI-guarded |
| `polkit/`, `bin/nova-power-gpu-mode-apply` | lets Settings choose the GPU mode without a password |
| `bin/nova-power-sleep-apply` | the root half of `nova power lid` and `hibernate`, through polkit too |
| `test/roundtrip.sh` | the policy's library half against fixtures; part of `make test` |
| `test/watts.sh` | the measuring stick: average draw on battery over N seconds |
