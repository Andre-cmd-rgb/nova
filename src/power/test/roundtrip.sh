#!/bin/bash
# Every tunable saves the firmware's value on the way to battery and puts it
# back on AC. That is easy to get wrong in ways nothing notices until you
# unplug for a week — the runtime-PM state file was truncated on every battery
# run for a while, so AC had nothing to restore and nobody saw it.
#
# The functions read their paths from globals, so the test points them at
# temporary files and drives the round trips directly. No root, no sysfs.
# The globals set here are read by the library half it sources.
# shellcheck disable=SC2034
set -uo pipefail
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
TOOL=$HERE/../bin/nova-power
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# Everything above the dispatch is the library half.
sed '/^cmd=\${1:-auto}/,$d' "$TOOL" > "$T/lib.sh"
grep -q '^aspm()' "$T/lib.sh" || { echo "could not extract the library half of $TOOL"; exit 1; }
CONFIG=/dev/null . "$T/lib.sh"

# Every /run path the library consults has to be redirected before the first
# tunable is exercised. This was learned the moment nova-powerd was
# actually installed: the real /run/nova-powerd.owns-cpu appeared, the
# library correctly stood down from the CPU registers, and eight checks that
# had passed all day started failing on a machine that was working perfectly.
# A test that reads host state is not a test.
BOOST_STATE=$T/boost
DAEMON_OWNS_CPU=$T/owns-cpu
DAEMON_STATE=$T/dstate
GPU_MANUAL=$T/gpu-manual
GPU_MODE_FILE=$T/gpu-mode
RUNTIME_PM_STATE=$T/runtime-pm

fail=0
chk() {
  if [[ $2 == "$3" ]]; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s: got %q want %q\n' "$1" "$2" "$3"; fail=1; fi
}

ASPM_ON_BAT=powersave ASPM_POLICY=$T/aspm ASPM_STATE=$T/aspm.state
echo '[default] performance powersave powersupersave' >"$ASPM_POLICY"
aspm battery
chk "aspm battery writes policy"   "$(cat "$ASPM_POLICY")" "powersave"
chk "aspm battery saves original"  "$(cat "$ASPM_STATE")"  "default"
aspm battery
chk "aspm battery idempotent"      "$(cat "$ASPM_STATE")"  "default"
aspm ac
chk "aspm ac restores"             "$(cat "$ASPM_POLICY")" "default"
chk "aspm ac clears state"         "$([[ -e $ASPM_STATE ]] && echo yes || echo no)" "no"

NMI_WATCHDOG_ON_BAT=off NMI_WATCHDOG=$T/nmi NMI_STATE=$T/nmi.state
echo 1 >"$NMI_WATCHDOG"
nmi_watchdog battery
chk "nmi battery disables"         "$(cat "$NMI_WATCHDOG")" "0"
nmi_watchdog ac
chk "nmi ac restores"              "$(cat "$NMI_WATCHDOG")" "1"

PL1_ON_BAT=30 RAPL_PL1=$T/pl1 RAPL_WINDOW=$T/win RAPL_STATE=$T/rapl.state
echo 109000000 >"$RAPL_PL1"; echo 55967744 >"$RAPL_WINDOW"
power_limit battery
chk "pl1 battery sets limit"       "$(cat "$RAPL_PL1")"    "30000000"
chk "pl1 battery shortens window"  "$(cat "$RAPL_WINDOW")" "10000000"
power_limit ac
chk "pl1 ac restores limit"        "$(cat "$RAPL_PL1")"    "109000000"
chk "pl1 ac restores window"       "$(cat "$RAPL_WINDOW")" "55967744"

# A bad wattage must be refused, not applied: this runs as root against a
# register that decides how much power the package may draw.
for bad in 2 abc -5 ''; do
  PL1_ON_BAT=$bad; echo 109000000 >"$RAPL_PL1"
  power_limit battery >/dev/null 2>&1
  chk "pl1 refuses '$bad'"         "$(cat "$RAPL_PL1")"    "109000000"
done

# PL2 is the burst limit and rides in the same state file, which grew a third
# field when it was added. Both halves round trip together.
PL1_ON_BAT=30 PL2_ON_BAT=45 RAPL_PL2=$T/pl2
echo 109000000 >"$RAPL_PL1"; echo 55967744 >"$RAPL_WINDOW"; echo 135000000 >"$RAPL_PL2"
rm -f "$RAPL_STATE"
power_limit battery
chk "pl2 battery sets burst"       "$(cat "$RAPL_PL2")"    "45000000"
power_limit ac
chk "pl2 ac restores burst"        "$(cat "$RAPL_PL2")"    "135000000"
chk "pl2 ac restores sustained"    "$(cat "$RAPL_PL1")"    "109000000"

# A burst limit under the sustained limit is a contradiction. PL1 must still be
# applied — refusing the whole function over PL2 would silently drop the knob
# that actually matters under load.
PL1_ON_BAT=30 PL2_ON_BAT=20
echo 109000000 >"$RAPL_PL1"; echo 135000000 >"$RAPL_PL2"; rm -f "$RAPL_STATE"
power_limit battery >/dev/null 2>&1
chk "pl2 below pl1 ignored"        "$(cat "$RAPL_PL2")"    "135000000"
chk "pl1 still applied"            "$(cat "$RAPL_PL1")"    "30000000"
power_limit ac

# A state file written before PL2 existed has two fields. /run is a tmpfs so
# this only happens across an upgrade inside one boot, which is exactly when
# nobody is looking.
PL1_ON_BAT=30 PL2_ON_BAT=45
echo 109000000 >"$RAPL_PL1"; echo 135000000 >"$RAPL_PL2"
printf '99000000 55967744\n' >"$RAPL_STATE"
power_limit ac
chk "pl2 tolerates a short state"  "$(cat "$RAPL_PL1")"    "99000000"
chk "pl2 left alone when unrecorded" "$(cat "$RAPL_PL2")"  "135000000"

# The frequency ceiling. Percent of the P-state range, and the driver rejects a
# maximum below the minimum, so that has to be caught here rather than by a
# write that fails silently.
CPU_MAX_PCT_ON_BAT=60 PSTATE_MAX=$T/maxpct PSTATE_MIN=$T/minpct PSTATE_STATE=$T/pct.state
echo 100 >"$PSTATE_MAX"; echo 16 >"$PSTATE_MIN"
cpu_ceiling battery
chk "ceiling battery caps"         "$(cat "$PSTATE_MAX")"  "60"
chk "ceiling battery saves"        "$(cat "$PSTATE_STATE")" "100"
cpu_ceiling ac
chk "ceiling ac restores"          "$(cat "$PSTATE_MAX")"  "100"
chk "ceiling ac clears state"      "$([[ -e $PSTATE_STATE ]] && echo yes || echo no)" "no"

for bad in 0 101 abc ''; do
  CPU_MAX_PCT_ON_BAT=$bad; echo 100 >"$PSTATE_MAX"
  cpu_ceiling battery >/dev/null 2>&1
  chk "ceiling refuses '$bad'"     "$(cat "$PSTATE_MAX")"  "100"
done
CPU_MAX_PCT_ON_BAT=10; echo 100 >"$PSTATE_MAX"
cpu_ceiling battery >/dev/null 2>&1
chk "ceiling refuses below min"    "$(cat "$PSTATE_MAX")"  "100"

# A boost must survive a resume, and the resume hook re-runs the whole battery
# policy. If the guard is missing, a build loses its headroom halfway through
# and nothing says why.
CPU_MAX_PCT_ON_BAT=60 PL1_ON_BAT=30 PL2_ON_BAT=45
echo 100 >"$PSTATE_MAX"; echo 109000000 >"$RAPL_PL1"; echo 135000000 >"$RAPL_PL2"
rm -f "$RAPL_STATE" "$PSTATE_STATE"
: >"$BOOST_STATE"
cpu_ceiling battery
power_limit battery
chk "boost blocks the ceiling"     "$(cat "$PSTATE_MAX")"  "100"
chk "boost blocks the power limit" "$(cat "$RAPL_PL1")"    "109000000"
rm -f "$BOOST_STATE"
cpu_ceiling battery
power_limit battery
chk "caps return once boost ends"  "$(cat "$PSTATE_MAX")"  "60"
chk "limits return once boost ends" "$(cat "$RAPL_PL1")"   "30000000"

# The governor owns PL1, PL2 and the ceiling whenever it is running, and this
# file must stand down. Two writers on the same register is fact 4 again, and
# the symptom would be the tiers being overwritten once every plug event by
# limits nobody asked for.
CPU_MAX_PCT_ON_BAT=60 PL1_ON_BAT=30 PL2_ON_BAT=45
echo 100 >"$PSTATE_MAX"; echo 109000000 >"$RAPL_PL1"; echo 135000000 >"$RAPL_PL2"
rm -f "$RAPL_STATE" "$PSTATE_STATE" "$BOOST_STATE"
: >"$DAEMON_OWNS_CPU"
power_limit battery
cpu_ceiling battery
chk "daemon owns the power limit"  "$(cat "$RAPL_PL1")"    "109000000"
chk "daemon owns the ceiling"      "$(cat "$PSTATE_MAX")"  "100"
chk "governor row reads the state" "$(governor_now)"       "starting up"
echo 'battery/full 91 74 held 23.4' >"$DAEMON_STATE"
chk "governor row formats state"   "$(governor_now)" "battery/full, 91% busy, 74 C, fans held, 23.4 W"
echo 'ac 3 51 auto ?' >"$DAEMON_STATE"
chk "governor row before a reading" "$(governor_now)" "ac, 3% busy, 51 C, fans auto"
echo 'battery/full 91 74 held' >"$DAEMON_STATE"
chk "governor row, an older daemon" "$(governor_now)" "battery/full, 91% busy, 74 C, fans held"
rm -f "$DAEMON_OWNS_CPU"
chk "governor row when absent"     "$(governor_now)"       "not running"
power_limit battery
cpu_ceiling battery
chk "caps return without a daemon" "$(cat "$RAPL_PL1")"    "30000000"

# Wi-Fi power save. There is no file to inspect afterwards — the flag lives in
# the driver — so `iw` is replaced by a stub that records its arguments. That
# is the whole reason wifi_powersave calls "$IW" rather than iw: an untested
# on/off mapping that turns the radio's power save off on battery would look
# exactly like a working one.
mkdir -p "$T/bin"
cat >"$T/bin/iw" <<'STUB'
#!/bin/sh
echo "$*" >>"$IW_LOG"
[ "$2" = get ] || [ "$3" = get ] || exit 0
echo "	Power save: on"
STUB
chmod +x "$T/bin/iw"
export IW_LOG=$T/iw.log
IW=$T/bin/iw
WIFI_NET_DIR=$T/net
mkdir -p "$WIFI_NET_DIR/wlp9s0/wireless" "$WIFI_NET_DIR/lo"

chk "wifi finds only wireless devices" "$(wifi_devices | tr '\n' ' ')" "wlp9s0 "

WIFI_POWERSAVE_ON_BAT=on
: >"$IW_LOG"; wifi_powersave battery
chk "wifi battery enables"         "$(cat "$IW_LOG")" "dev wlp9s0 set power_save on"
: >"$IW_LOG"; wifi_powersave ac
chk "wifi ac disables"             "$(cat "$IW_LOG")" "dev wlp9s0 set power_save off"

# The knob is the user's way of disagreeing with the AX210 reasoning, so it has
# to stop the write, not just change what is written.
WIFI_POWERSAVE_ON_BAT=off
: >"$IW_LOG"; wifi_powersave battery
chk "wifi off knob writes nothing"  "$(cat "$IW_LOG")" ""

# status runs unprivileged and must never print a bare label with no value.
WIFI_POWERSAVE_ON_BAT=on
chk "wifi status reads the flag"    "$(wifi_powersave_now)" "wlp9s0 on"
WIFI_NET_DIR=$T/net-empty; mkdir -p "$WIFI_NET_DIR"
chk "wifi status with no radio"     "$(wifi_powersave_now)" "no wireless device"
WIFI_NET_DIR=$T/net

# doctor's boot figures. An awk program printed a label and no number for two
# commits because the only run during development hit the root guard, so
# anything with awk in it gets driven against real input here. efivarfs puts
# four attribute bytes in front of the value, which is the part that is easy
# to be off by one on.
EFIVARS=$T/efivars; mkdir -p "$EFIVARS"
efivar() { printf '\x07\x00\x00\x00%s' "$2" >"$EFIVARS/$1-8be4df61-93ca-11d2-aa0d-00e098032b8c"; }

efivar LoaderTimeInitUSec 11496098
efivar LoaderTimeExecUSec 20604018
chk "boot firmware figure"  "$(boot_timing | sed -n 1p)" "    firmware (POST)         11.50 s"
chk "boot loader figure"    "$(boot_timing | sed -n 2p)" "    boot loader              9.11 s"

# Nothing to print is a legitimate answer, and must not be a blank number.
rm -f "$EFIVARS"/LoaderTimeExecUSec-*
chk "boot half-recorded"    "$(boot_timing; echo "rc=$?")" "rc=1"
rm -f "$EFIVARS"/LoaderTime*
chk "boot unrecorded"       "$(boot_timing; echo "rc=$?")" "rc=1"

# Firmware can write anything into an efivar; a garbage value must not reach awk.
efivar LoaderTimeInitUSec 11496098
efivar LoaderTimeExecUSec 'not-a-number'
chk "boot rejects garbage"  "$(boot_timing; echo "rc=$?")" "rc=1"
efivar LoaderTimeExecUSec 900
chk "boot rejects backwards" "$(boot_timing; echo "rc=$?")" "rc=1"

# ---------------------------------------------------------------- the GPU half
#
# This is the part that used to decline 96 times a fortnight with a message
# that named nothing. All three functions read kernel surfaces, so they get a
# fixture built from what this machine actually prints — fact 18: an awk
# program that has never been run against real input is not known to work.

SYS_PCI=$T/pci
DEV_DRI=$T/dri
PROC_MODULES=$T/modules
NVIDIA_PCI=0000:01:00.0

# /proc/modules as it reads with the card bound. Field 3 is the reference
# count, field 4 the modules holding those references; "-" there means the
# references are open file descriptors, which is the case worth naming.
cat >"$PROC_MODULES" <<'MODS'
nvidia_drm 131072 4 - Live 0xffffffffc2a00000 (POE)
nvidia_modeset 1572864 6 nvidia_drm, Live 0xffffffffc2880000 (POE)
nvidia_uvm 3407872 0 - Live 0xffffffffc2500000 (POE)
nvidia 95420416 20 nvidia_uvm,nvidia_modeset, Live 0xffffffffc0a00000 (POE)
i915 4articulate 0 - Live 0xffffffffc0000000
MODS

chk "module_refs names the fd holder"  "$(module_refs nvidia_drm)"      "4, held by -"
chk "module_refs names module holders" "$(module_refs nvidia_modeset)"  "6, held by nvidia_drm,"
chk "module_refs on an absent module"  "$(module_refs nvidia_peermem)"  ""
chk "all four still loaded"            "$(modules_still_loaded)" \
                                       "nvidia_drm nvidia_modeset nvidia_uvm nvidia"

: >"$PROC_MODULES"
chk "none loaded reads empty"          "$(modules_still_loaded)" ""

# A partial unload is the state that matters: gpu_off must not conclude it is
# finished while one module is still resident holding the card.
echo 'nvidia 95420416 0 - Live 0xffffffffc0a00000 (POE)' >"$PROC_MODULES"
chk "a single survivor is reported"    "$(modules_still_loaded)" "nvidia"

# gpu_drm_nodes: `modeset=1` gives the card a DRM node, and an fd on that node
# pins nvidia_drm exactly as hard as an fd on /dev/nvidia0. Numbering is probe
# order, so the node is read off the device and never assumed to be card0.
mkdir -p "$SYS_PCI/$NVIDIA_PCI/drm/card0" "$SYS_PCI/$NVIDIA_PCI/drm/renderD128"
mkdir -p "$SYS_PCI/$NVIDIA_PCI/drm/card0-DP-1" "$DEV_DRI"
touch "$DEV_DRI/card0" "$DEV_DRI/renderD128"
chk "drm nodes found off the device"   "$(gpu_drm_nodes | tr '\n' ' ')" \
                                       "$DEV_DRI/card0 $DEV_DRI/renderD128 "

# The card/render split, which is the whole of fact 48. On any logind system
# the card node is open for the life of the session by systemd, logind and the
# compositor on a completely idle card, so it must never reach the veto. The
# render node means somebody is actually drawing on the card, so it must.
chk "render nodes alone"               "$(gpu_drm_nodes render | tr '\n' ' ')" \
                                       "$DEV_DRI/renderD128 "
chk "card nodes alone"                 "$(gpu_drm_nodes card | tr '\n' ' ')" \
                                       "$DEV_DRI/card0 "

# fuser is shadowed to put holders on the card node and nowhere else — the
# exact shape that declined every two minutes for five hours on 2026-09-04.
fuser() { case $1 in */card0) echo ' 814 1393' ;; *) return 1 ;; esac; }
chk "card-node holders do not veto"    "$(gpu_consumers)" ""
chk "  and are still named on failure" "$(gpu_users)" "814 1393 "

# A holder on the render node is a real user, and switching off underneath it
# is the thing this tool must not do.
fuser() { case $1 in */renderD128) echo ' 40094' ;; *) return 1 ;; esac; }
chk "render-node holder vetoes"        "$(gpu_consumers)" "40094 "
unset -f fuser

# A connector directory is not a node. Listing card0-DP-1 would hand fuser a
# path that does not exist and quietly return no holders for the real one.
rm -f "$DEV_DRI/renderD128"
chk "a node with no /dev entry is skipped" "$(gpu_drm_nodes | tr '\n' ' ')" \
                                           "$DEV_DRI/card0 "

# Off the bus there is no drm/ directory at all, and the glob must not leak
# its own unexpanded pattern into a path fuser would then be handed.
rm -rf "${SYS_PCI:?}/${NVIDIA_PCI:?}"
chk "no device means no nodes"         "$(gpu_drm_nodes)" ""
chk "gpu_present false once removed"   "$(gpu_present && echo yes || echo no)" "no"

# The PCI removal path, which is the one that has cost this machine a panic.
# Highest function first, so function 0 — and the card's power — goes last.
mkdir -p "$SYS_PCI/0000:01:00.0" "$SYS_PCI/0000:01:00.1"
: >"$SYS_PCI/0000:01:00.0/remove"; : >"$SYS_PCI/0000:01:00.1/remove"
chk "both functions enumerated"        "$(gpu_slot_functions | tr '\n' ' ')" \
                                       "0000:01:00.0 0000:01:00.1 "

# The retry is the new behaviour and the reason the boot case stopped costing
# two minutes, so it is driven directly. `modprobe` and `sleep` are shadowed:
# the point is the control flow, and a test that waits six real seconds to
# prove it waited is its own kind of bug.
attempts=0
sleep() { :; }
modprobe() {
  # -r <module>: drop it from the fixture, standing in for a real unload.
  local m=${3:-$2}
  ((attempts++))
  ((attempts > unload_frees_after)) || return 1
  # `|| true`, because grep exits 1 when it filters out every line — which is
  # exactly what removing the last module looks like, and without this the
  # shim silently kept it.
  grep -v "^$m " "$PROC_MODULES" >"$PROC_MODULES.tmp" || true
  mv "$PROC_MODULES.tmp" "$PROC_MODULES"
}
fixture() {
  cat >"$PROC_MODULES" <<'MODS'
nvidia_drm 131072 4 - Live 0x0 (POE)
nvidia_modeset 1572864 6 nvidia_drm, Live 0x0 (POE)
nvidia_uvm 3407872 0 - Live 0x0 (POE)
nvidia 95420416 20 nvidia_uvm,nvidia_modeset, Live 0x0 (POE)
MODS
}

# A holder that lets go straight away: one pass, no waiting.
fixture; attempts=0; unload_frees_after=0
out=$(unload_nvidia_modules 2>&1); rc=$?
chk "unload succeeds when nothing holds"  "$rc"  "0"
chk "  and says nothing while succeeding" "$out" ""
chk "  and leaves the fixture empty"      "$(modules_still_loaded)" ""

# A transient holder — the greeter on its way out, a udev worker still
# settling. This is the case that used to hand the whole question to a timer
# two minutes away, with the card powered for the whole gap.
fixture; attempts=0; unload_frees_after=4
out=$(unload_nvidia_modules 2>&1); rc=$?
chk "unload retries past a transient hold" "$rc" "0"
chk "  and clears every module"            "$(modules_still_loaded)" ""

# A real holder: decline, and name it. The old message named nothing at all.
fixture; attempts=0; unload_frees_after=9999
out=$(unload_nvidia_modules 2>&1); rc=$?
chk "unload gives up on a real holder"     "$rc" "1"
chk "  and names the module"     "$(grep -c 'nvidia_drm would not unload' <<<"$out")" "1"
chk "  and quotes the refcount"  "$(grep -c 'refs: 4, held by -'          <<<"$out")" "1"
unset -f modprobe sleep

# ---------------------------------------------------------------- the GPU mode
#
# Settings' choice: auto wants the card on with AC only, off never; anything
# else in the file is auto.
on_ac() { ((ac)); }
ac=1
chk "no mode file is auto"              "$(gpu_mode)" "auto"
echo banana >"$GPU_MODE_FILE"
chk "an unknown mode is auto"           "$(gpu_mode)" "auto"
chk "  which wants the card on AC"      "$(gpu_wanted && echo on || echo off)" "on"
ac=0
chk "  and off on battery"              "$(gpu_wanted && echo on || echo off)" "off"
echo off >"$GPU_MODE_FILE"; ac=1
chk "off wants it off on AC as well"    "$(gpu_wanted && echo on || echo off)" "off"
unset -f on_ac

# A rescan that does not bring the card back puts the modprobe block back:
# with the card absent, it is what keeps nvidia-modprobe off the bus.
NVIDIA_PCI=0000:01:00.0 SYS_PCI=$T/pci/devices MODPROBE_BLOCK=$T/modprobe-block
mkdir -p "$SYS_PCI"
sleep() { :; }
gpu_on >/dev/null 2>&1
chk "a failed rescan asks for one"      "$(cat "$T/pci/rescan" 2>/dev/null)" "1"
chk "  and keeps the driver blocked"    "$([[ -s $MODPROBE_BLOCK ]] && echo yes || echo no)" "yes"
unset -f sleep

# Settings' readout, from the same files.
RAPL_PL1=$T/pl1 RAPL_PL2=$T/pl2 PSTATE_MAX=$T/max PSTATE_NO_TURBO=$T/no-turbo
FAN_PROC=$T/fan BAT_POWER=$T/power-now BOOST_STATE=$T/boost
echo 18000000 >"$RAPL_PL1"; echo 28000000 >"$RAPL_PL2"; echo 70 >"$PSTATE_MAX"; echo 0 >"$PSTATE_NO_TURBO"
printf 'status:\t\tenabled\nspeed:\t\t2581\nlevel:\t\t2\n' >"$FAN_PROC"
echo 9870000 >"$BAT_POWER"
: >"$DAEMON_OWNS_CPU"; echo 'battery/mid 71 64 held 11.3' >"$DAEMON_STATE"; : >"$BOOST_STATE"
on_ac() { return 1; }
chk "readout on battery"           "$(status_json)" \
  '{"source":"battery","governor":{"tier":"mid","busy":71,"temp":64,"fans":"held","watts":11.3},"pl1":18,"pl2":28,"ceiling":70,"turbo":true,"boost":true,"fanRpm":2581,"batteryWatts":9.87}'
echo 'ac 3 ? ec ?' >"$DAEMON_STATE"; echo 1 >"$PSTATE_NO_TURBO"; rm -f "$BOOST_STATE" "$FAN_PROC"
on_ac() { return 0; }
chk "readout, a figure missing"    "$(status_json)" \
  '{"source":"ac","governor":{"tier":null,"busy":3,"temp":null,"fans":"ec","watts":null},"pl1":18,"pl2":28,"ceiling":70,"turbo":false,"boost":false,"fanRpm":null,"batteryWatts":null}'
rm -f "$DAEMON_OWNS_CPU"
chk "readout without the governor" "$(status_json | jq -c .governor)" "null"
unset -f on_ac

echo
if ((fail)); then echo "FAILURES"; exit 1; else echo "all pass"; fi
