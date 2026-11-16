// ---------------------------------------------------------------- paths

pub(crate) const CONFIG: &str = "/etc/nova/power.conf";
pub(crate) const RAPL: &str = "/sys/class/powercap/intel-rapl:0";
// The package's second copy of the same limits, mapped into memory; the lower
// of the two copies is the one in force.
pub(crate) const RAPL_MMIO: &str = "/sys/class/powercap/intel-rapl-mmio:0";
pub(crate) const PSTATE_MAX: &str = "/sys/devices/system/cpu/intel_pstate/max_perf_pct";
pub(crate) const PSTATE_MIN: &str = "/sys/devices/system/cpu/intel_pstate/min_perf_pct";
pub(crate) const PSTATE_NO_TURBO: &str = "/sys/devices/system/cpu/intel_pstate/no_turbo";
pub(crate) const FAN: &str = "/proc/acpi/ibm/fan";
// The bash half checks for this before touching PL1, PL2 or max_perf_pct. Two
// things writing the same register is how the power profiles were lost the
// first time round; this is the same hazard with a file in front of it.
pub(crate) const OWNS_CPU: &str = "/run/nova-powerd.owns-cpu";
// What the firmware had before anything here ran. Persisted because a daemon
// restart would otherwise record our own capped values as the originals and
// there would be no way back to the real ones without a reboot.
pub(crate) const FIRMWARE: &str = "/run/nova-powerd.firmware";
// One line, for `nova power status` and Settings' readout: mode, busy
// percent, package temperature, fans, package watts.
pub(crate) const STATE: &str = "/run/nova-powerd.state";
// Written by `nova power boost`. Shared with the bash half deliberately:
// one boost, one file, whichever half is asked.
pub(crate) const BOOST: &str = "/run/nova-power.boost";
// The bash half's own save files. If it capped the registers before this
// started, these hold what the firmware actually had — which is the only
// honest source for "restore everything" on AC.
pub(crate) const BASH_RAPL_STATE: &str = "/run/nova-power.rapl";
pub(crate) const BASH_PCT_STATE: &str = "/run/nova-power.cpupct";
