// nova-powerd — the continuous half of nova-power.
//
// nova-power itself is edge-triggered: it runs on a plug event, at boot and
// after resume, and it decides one thing per edge. That is the right shape for
// the discrete GPU, which you either have on the bus or you do not. It is the
// wrong shape for the CPU.
//
// The CPU problem is that firmware gives you exactly the opposite of what a
// laptop wants. RAPL's PL1/PL2 pair is "high briefly, low sustained": a burst
// gets 135 W on this machine and a long job gets throttled. What you actually
// want is "low briefly, high sustained" — a browser spike should never reach
// 4.8 GHz to scroll a page, and a compile should have everything. No register
// does that, because it is a policy about *time*, and policies about time need
// something awake to watch the clock. Hence a daemon.
//
// So: four tiers on battery, a dwell time before climbing, a longer one before
// falling, and the battery's mode (saver, balanced, performance) deciding which
// of them it may use. The temperature guard outranks the load state. On AC,
// one mode: everything, to Nova's own limits, held there. The fans follow
// Nova's own curves, one plugged in and one on battery, and the fan watchdog
// outranks everything: if this process dies the EC has the fans back within
// thirty seconds without anyone having to notice.
//
// It owns PL1, PL2, max_perf_pct and the fans, and nothing else. EPP and the
// platform profile belong to power-profiles-daemon (fact 4 in
// docs/hardware/thinkpad-p1-gen4i.md, learned by taking them and losing).

use std::collections::HashMap;
use std::fs;
use std::io::Write;

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

// Three symbols, declared rather than depended on. Rust links libc on this
// target anyway, so a crate for it would be a supply chain for nothing.
extern "C" {
    fn signal(sig: i32, handler: usize) -> usize;
}
const SIGTERM: i32 = 15;
const SIGINT: i32 = 2;
const SIGHUP: i32 = 1;

static STOPPING: AtomicBool = AtomicBool::new(false);
static RELOAD: AtomicBool = AtomicBool::new(false);

// Async-signal-safe: it sets a flag and returns. Everything else waits for the
// top of the loop.
extern "C" fn on_signal(sig: i32) {
    if sig == SIGHUP {
        RELOAD.store(true, Ordering::SeqCst);
    } else {
        STOPPING.store(true, Ordering::SeqCst);
    }
}

// ---------------------------------------------------------------- paths

const CONFIG: &str = "/etc/nova/power.conf";
const RAPL: &str = "/sys/class/powercap/intel-rapl:0";
// The package's second copy of the same limits, mapped into memory; the lower
// of the two copies is the one in force.
const RAPL_MMIO: &str = "/sys/class/powercap/intel-rapl-mmio:0";
const PSTATE_MAX: &str = "/sys/devices/system/cpu/intel_pstate/max_perf_pct";
const PSTATE_MIN: &str = "/sys/devices/system/cpu/intel_pstate/min_perf_pct";
const PSTATE_NO_TURBO: &str = "/sys/devices/system/cpu/intel_pstate/no_turbo";
const FAN: &str = "/proc/acpi/ibm/fan";
// The bash half checks for this before touching PL1, PL2 or max_perf_pct. Two
// things writing the same register is how the power profiles were lost the
// first time round; this is the same hazard with a file in front of it.
const OWNS_CPU: &str = "/run/nova-powerd.owns-cpu";
// What the firmware had before anything here ran. Persisted because a daemon
// restart would otherwise record our own capped values as the originals and
// there would be no way back to the real ones without a reboot.
const FIRMWARE: &str = "/run/nova-powerd.firmware";
// One line, for `nova power status` and Settings' readout: mode, busy
// percent, package temperature, fans, package watts.
const STATE: &str = "/run/nova-powerd.state";
// Written by `nova power boost`. Shared with the bash half deliberately:
// one boost, one file, whichever half is asked.
const BOOST: &str = "/run/nova-power.boost";
// The bash half's own save files. If it capped the registers before this
// started, these hold what the firmware actually had — which is the only
// honest source for "restore everything" on AC.
const BASH_RAPL_STATE: &str = "/run/nova-power.rapl";
const BASH_PCT_STATE: &str = "/run/nova-power.cpupct";

// ---------------------------------------------------------------- config

#[derive(Clone, Debug)]
struct Config {
    poll_ms: u64,
    // Tiers, battery only. AC restores firmware and gets out of the way.
    tiers: Vec<Tier>,
    // Percent busy across all CPUs that counts as work worth unlocking for,
    // and the quieter figure that counts as done.
    busy_climb: f64,
    busy_fall: f64,
    // The whole point: a spike has to persist to be believed.
    climb_after: Duration,
    fall_after: Duration,
    // Above this the load state stops mattering.
    temp_throttle: f64,
    // Above this for three polls the fans go to full speed, whatever the
    // curve says.
    temp_critical: f64,
    fan_control: bool,
    fan_watchdog_secs: u64,
    // Plugged in, in watts: the most the package may draw, held in both
    // copies. Its heat, not these, is what limits it there.
    ac_pl1_w: u64,
    ac_pl2_w: u64,
    enabled: bool,
}

#[derive(Clone, Copy, Debug, PartialEq)]
struct Tier {
    name: &'static str,
    pl1_w: u64,
    pl2_w: u64,
    max_pct: u64,
    // Turbo off outright, rather than only unreachable via the ceiling. A
    // ceiling below the base ratio already prevents it, but this says so to
    // the driver instead of implying it, and it is the knob people look for.
    no_turbo: bool,
    // The iGPU's own ceiling, in MHz. 0 leaves it to the driver.
    //
    // This is the other half of the package budget and it is easy to miss:
    // intel-rapl:0 covers core *and* uncore, and the iGPU spends out of the
    // same watts. Measured here with a windowed 4K YouTube playing, the iGPU
    // sat at 1100-1200 MHz against a 350 MHz floor — to composite a desktop,
    // not to decode anything. i915's waitboost is why: a client stalling on a
    // buffer boosts the GPU to gt_boost_freq_mhz, which ships at RP0.
    gpu_mhz: u64,
}

impl Default for Config {
    // The tier table reads as a table; rustfmt would put every field on its own line.
    #[rustfmt::skip]
    fn default() -> Self {
        Config {
            poll_ms: 1000,
            tiers: vec![
                // Reading, scrolling, a video. The ceiling is where the watts
                // are: power goes roughly as f times V squared and V tracks f,
                // so the top of the curve costs several times what it returns.
                // 45% of 4.8 GHz is about 2.16 GHz, comfortably under the
                // 2.5 GHz base ratio, so turbo cannot be reached even before
                // no_turbo says so.
                //
                // PL1 is the safety net rather than the lever, and it does not
                // go lower than this on purpose: intel-rapl:0 is the *package*
                // domain, with core and uncore beneath it, so the iGPU spends
                // out of the same budget. 4K video decode plus a 3840x2400
                // display pipeline is several watts of that, and a PL1 tight
                // enough to look impressive here is a PL1 that stutters video.
                Tier { name: "light", pl1_w: 12, pl2_w: 18, max_pct: 45, no_turbo: true, gpu_mhz: 800 },
                // Something is genuinely working but has not earned the fan.
                Tier { name: "mid", pl1_w: 18, pl2_w: 28, max_pct: 70, no_turbo: false, gpu_mhz: 1050 },
                // A compile, an export, a container build.
                Tier { name: "full", pl1_w: 28, pl2_w: 42, max_pct: 100, no_turbo: false, gpu_mhz: 0 },
                // Prolonged hammering: about a minute of unbroken load by the
                // time this is reached. At that point the work is real and
                // finishing it sooner is the efficient thing — a job that takes
                // twice as long at half the power is not a saving, and the
                // sooner the package is idle the sooner everything else is too.
                Tier { name: "turbo", pl1_w: 40, pl2_w: 60, max_pct: 100, no_turbo: false, gpu_mhz: 0 },
            ],
            busy_climb: 65.0,
            busy_fall: 30.0,
            // Long enough that no interaction reaches it. A page load is
            // hundreds of milliseconds; nothing you do with a mouse is eight
            // seconds of sustained multi-core load.
            climb_after: Duration::from_secs(8),
            // Longer than the climb, so a compile's gaps between files do not
            // drop it back a tier and pay the ramp again.
            fall_after: Duration::from_secs(25),
            temp_throttle: 85.0,
            temp_critical: 92.0,
            // On by default, but gated on thinkpad_acpi actually permitting it
            // — see Fans::new. Before the modprobe option takes effect at the
            // next boot this is a no-op with one line of explanation, which is
            // better than a knob that has to be found and turned on later.
            fan_control: true,
            fan_watchdog_secs: 30,
            // The firmware's own figures on this machine. Under a long load
            // the package reaches its 96 °C first, at 50-60 W (fact 50), so
            // anything lower would only take back the first seconds of a
            // burst, and the cooling is what is worth having more of.
            ac_pl1_w: 109,
            ac_pl2_w: 135,
            enabled: true,
        }
    }
}

// The config file is shell, and is read by the bash half with `.`, so this
// parser only has to understand the subset that is also valid shell: KEY=value,
// optional quotes, # comments. Anything it does not recognise is left to the
// other half rather than treated as an error.
fn parse_config(path: &str) -> HashMap<String, String> {
    let mut out = HashMap::new();
    let Ok(text) = fs::read_to_string(path) else {
        return out;
    };
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let line = line.strip_prefix("export ").unwrap_or(line);
        let Some((k, v)) = line.split_once('=') else {
            continue;
        };
        let k = k.trim();
        if k.is_empty() || !k.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') {
            continue;
        }
        let mut v = v.trim();
        // Strip an inline comment only outside quotes, which is all this needs.
        if !v.starts_with('"') && !v.starts_with('\'') {
            if let Some(i) = v.find(" #") {
                v = v[..i].trim();
            }
        }
        let v = v.trim_matches(|c| c == '"' || c == '\'');
        out.insert(k.to_string(), v.to_string());
    }
    out
}

impl Config {
    fn load() -> Self {
        let mut c = Config::default();
        let kv = parse_config(CONFIG);
        let num = |k: &str| kv.get(k).and_then(|v| v.parse::<u64>().ok());
        let flt = |k: &str| kv.get(k).and_then(|v| v.parse::<f64>().ok());
        let onoff = |k: &str| kv.get(k).map(|v| v == "on" || v == "yes" || v == "1");

        if let Some(v) = onoff("GOVERNOR") {
            c.enabled = v;
        }
        if let Some(v) = num("GOVERNOR_POLL_MS") {
            c.poll_ms = v.clamp(200, 10_000);
        }
        if let Some(v) = flt("GOVERNOR_BUSY_CLIMB") {
            c.busy_climb = v.clamp(1.0, 100.0);
        }
        if let Some(v) = flt("GOVERNOR_BUSY_FALL") {
            c.busy_fall = v.clamp(0.0, 99.0);
        }
        if let Some(v) = num("GOVERNOR_CLIMB_AFTER") {
            c.climb_after = Duration::from_secs(v.clamp(1, 600));
        }
        if let Some(v) = num("GOVERNOR_FALL_AFTER") {
            c.fall_after = Duration::from_secs(v.clamp(1, 3600));
        }
        if let Some(v) = flt("GOVERNOR_TEMP_THROTTLE") {
            c.temp_throttle = v.clamp(50.0, 100.0);
        }
        if let Some(v) = flt("GOVERNOR_TEMP_CRITICAL") {
            c.temp_critical = v.clamp(60.0, 105.0);
        }
        if let Some(v) = onoff("FAN_CONTROL") {
            c.fan_control = v;
        }
        if let Some(v) = num("FAN_WATCHDOG") {
            c.fan_watchdog_secs = v.clamp(5, 120);
        }
        if let Some(v) = num("AC_PL1") {
            c.ac_pl1_w = v.clamp(5, 200);
        }
        if let Some(v) = num("AC_PL2") {
            c.ac_pl2_w = v.clamp(5, 250);
        }
        c.ac_pl2_w = c.ac_pl2_w.max(c.ac_pl1_w);

        // The tiers, each overridable on its own. A partial override is a
        // legitimate thing to want — the light ceiling is the one people
        // actually tune — so this does not require all nine values.
        for (i, prefix) in ["LIGHT", "MID", "FULL", "TURBO"].iter().enumerate() {
            if let Some(v) = num(&format!("{prefix}_PL1")) {
                c.tiers[i].pl1_w = v.clamp(5, 200);
            }
            if let Some(v) = num(&format!("{prefix}_PL2")) {
                c.tiers[i].pl2_w = v.clamp(5, 250);
            }
            if let Some(v) = num(&format!("{prefix}_MAX_PCT")) {
                c.tiers[i].max_pct = v.clamp(1, 100);
            }
            if let Some(v) = onoff(&format!("{prefix}_NO_TURBO")) {
                c.tiers[i].no_turbo = v;
            }
            if let Some(v) = num(&format!("{prefix}_GPU_MHZ")) {
                c.tiers[i].gpu_mhz = v.min(5000);
            }
        }
        // A burst limit under the sustained limit is a contradiction, and the
        // bash half refuses one rather than writing it. Same rule here, except
        // that here it is a clamp: the daemon has to produce *some* tier.
        for t in c.tiers.iter_mut() {
            if t.pl2_w < t.pl1_w {
                t.pl2_w = t.pl1_w;
            }
        }
        // Tiers that do not increase are a configuration mistake that would
        // make the state machine meaningless rather than merely wrong.
        for i in 1..c.tiers.len() {
            if c.tiers[i].max_pct < c.tiers[i - 1].max_pct {
                c.tiers[i].max_pct = c.tiers[i - 1].max_pct;
            }
        }
        if c.busy_fall >= c.busy_climb {
            c.busy_fall = (c.busy_climb - 10.0).max(0.0);
        }
        c
    }
}

// ---------------------------------------------------------------- sysfs

// stdout into a journald pipe is block-buffered, so a tier change would sit in
// the buffer until something else filled it. Every line here is an event worth
// having a timestamp on, and there are only a handful a day.
macro_rules! say {
    ($($a:tt)*) => {{
        println!($($a)*);
        let _ = std::io::stdout().flush();
    }};
}

fn read_trim(path: impl AsRef<Path>) -> Option<String> {
    fs::read_to_string(path).ok().map(|s| s.trim().to_string())
}

fn read_u64(path: impl AsRef<Path>) -> Option<u64> {
    read_trim(path)?.parse().ok()
}

// Writes are best-effort and noisy exactly once. A sysfs file that has gone
// read-only, or a register firmware has taken back, would otherwise produce a
// line a second forever, and a log nobody reads is the same as no log.
struct Writer {
    complained: std::collections::HashSet<PathBuf>,
}

impl Writer {
    fn new() -> Self {
        Writer {
            complained: std::collections::HashSet::new(),
        }
    }

    fn write(&mut self, path: impl AsRef<Path>, value: &str) -> bool {
        let path = path.as_ref();
        match fs::OpenOptions::new().write(true).open(path) {
            Ok(mut f) => match f.write_all(value.as_bytes()) {
                Ok(()) => {
                    self.complained.remove(path);
                    true
                }
                Err(e) => {
                    self.complain(path, &format!("write failed: {e}"));
                    false
                }
            },
            Err(e) => {
                self.complain(path, &format!("open failed: {e}"));
                false
            }
        }
    }

    fn complain(&mut self, path: &Path, what: &str) {
        if self.complained.insert(path.to_path_buf()) {
            eprintln!("{}: {what}", path.display());
        }
    }
}

// ---------------------------------------------------------------- inputs

// Busy percent across every CPU, from the aggregate line of /proc/stat. iowait
// is not busy: a build waiting on the NVMe is not asking for frequency, and
// counting it would unlock the caps for something the CPU is not doing.
struct CpuSampler {
    last_busy: u64,
    last_total: u64,
}

impl CpuSampler {
    fn new() -> Self {
        let (b, t) = Self::read().unwrap_or((0, 0));
        CpuSampler {
            last_busy: b,
            last_total: t,
        }
    }

    fn read() -> Option<(u64, u64)> {
        let stat = fs::read_to_string("/proc/stat").ok()?;
        let line = stat.lines().next()?;
        let mut it = line.split_whitespace();
        if it.next()? != "cpu" {
            return None;
        }
        let v: Vec<u64> = it.filter_map(|f| f.parse().ok()).collect();
        if v.len() < 5 {
            return None;
        }
        let total: u64 = v.iter().sum();
        let idle = v[3] + v[4]; // idle + iowait
        Some((total.saturating_sub(idle), total))
    }

    fn busy_pct(&mut self) -> f64 {
        let Some((busy, total)) = Self::read() else {
            return 0.0;
        };
        let db = busy.saturating_sub(self.last_busy) as f64;
        let dt = total.saturating_sub(self.last_total) as f64;
        self.last_busy = busy;
        self.last_total = total;
        // A resume hands back a jump in both counters; the ratio survives it,
        // and a zero window (two reads inside one tick) is not a division.
        if dt <= 0.0 {
            0.0
        } else {
            (db / dt * 100.0).clamp(0.0, 100.0)
        }
    }
}

// What the package draws, from RAPL's energy counter. Plugged in, nothing else
// says: the battery reports only its own flow. The counter is root's to read
// (it leaks what the CPU is doing), so this is the one place that can.
struct PackageMeter {
    range_uj: u64,
    last: Option<(u64, Instant)>,
}

impl PackageMeter {
    fn new() -> Self {
        PackageMeter {
            range_uj: read_u64(format!("{RAPL}/max_energy_range_uj")).unwrap_or(0),
            last: None,
        }
    }

    // None for the first reading, and after forget(): one reading is no rate.
    fn watts(&mut self, now: Instant) -> Option<f64> {
        let Some(uj) = read_u64(format!("{RAPL}/energy_uj")) else {
            self.last = None;
            return None;
        };
        let (was, then) = self.last.replace((uj, now))?;
        watts_between(was, uj, self.range_uj, now.duration_since(then))
    }

    // A resume: firmware resets the counter across one.
    fn forget(&mut self) {
        self.last = None;
    }
}

// The counter wraps at range_uj, every hour or so at full load.
fn watts_between(was: u64, now: u64, range_uj: u64, dt: Duration) -> Option<f64> {
    let used = if now >= was {
        now - was
    } else if range_uj > was {
        range_uj - was + now
    } else {
        return None;
    };
    let secs = dt.as_secs_f64();
    (secs > 0.0).then(|| used as f64 / secs / 1e6)
}

// The package's temperature. x86_pkg_temp is the one that matters and it is a
// thermal zone rather than an hwmon here, so it is found by type rather than by
// a path that renumbers, once, and again only when the read fails. It is the
// CPU's own sensor and free to read; the firmware's TCPU is asked of the EC
// through ACPI, some six interrupts a read, so it stands in only where there
// is no x86_pkg_temp.
struct PackageTemp {
    zone: Option<PathBuf>,
}

impl PackageTemp {
    fn new() -> Self {
        PackageTemp { zone: Self::find() }
    }

    fn find() -> Option<PathBuf> {
        let mut fallback = None;
        for e in fs::read_dir("/sys/class/thermal").ok()?.flatten() {
            let p = e.path();
            match read_trim(p.join("type")).as_deref() {
                Some("x86_pkg_temp") => return Some(p.join("temp")),
                Some("TCPU") => fallback = Some(p.join("temp")),
                _ => {}
            }
        }
        fallback
    }

    fn read(&mut self) -> Option<f64> {
        let mc = match self.zone.as_ref().and_then(read_u64) {
            Some(mc) => mc,
            None => {
                self.zone = Self::find();
                self.zone.as_ref().and_then(read_u64)?
            }
        };
        Some(mc as f64 / 1000.0)
    }
}

// The EC's own sensors, as thinkpad_acpi lists them: the CPU as the EC sees
// it, the discrete GPU, and the board. The GPU's reads fail while it sleeps
// (a sleeping card makes no heat), and read the card as it is while it is
// awake, without waking it: the one way to see it that nvidia-smi does not
// spoil. Each read asks the EC, so they are read every few seconds, and the
// hottest kept between.
struct EcSensors {
    inputs: Vec<PathBuf>,
    hottest: Option<f64>,
    read_at: Option<Instant>,
}

impl EcSensors {
    fn find() -> EcSensors {
        let mut inputs = Vec::new();
        for e in fs::read_dir("/sys/class/hwmon")
            .into_iter()
            .flatten()
            .flatten()
        {
            let p = e.path();
            if read_trim(p.join("name")).as_deref() != Some("thinkpad") {
                continue;
            }
            for i in 1..=16 {
                let input = p.join(format!("temp{i}_input"));
                if input.exists() {
                    inputs.push(input);
                }
            }
        }
        EcSensors {
            inputs,
            hottest: None,
            read_at: None,
        }
    }

    fn hottest(&mut self, now: Instant) -> Option<f64> {
        if self
            .read_at
            .is_none_or(|t| now.duration_since(t) >= Duration::from_secs(3))
        {
            self.read_at = Some(now);
            self.hottest = self
                .inputs
                .iter()
                .filter_map(|p| read_trim(p)?.parse::<i64>().ok())
                .filter_map(ec_celsius)
                .reduce(f64::max);
        }
        self.hottest
    }
}

// A sensor the EC has nothing for reads 0, or -128 °C.
fn ec_celsius(mc: i64) -> Option<f64> {
    (mc > 0 && mc < 128_000).then(|| mc as f64 / 1000.0)
}

// ---------------------------------------------------------------- modes

// The battery's three modes, as power-profiles-daemon sets them from the menu
// and Settings: the platform profile it writes, or, without one, the CPU's
// energy preference. Plugged in there is one mode, full power, and
// nova-power-profile keeps the profile on performance there.
const PLATFORM_PROFILE: &str = "/sys/firmware/acpi/platform_profile";
const EPP: &str = "/sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference";

#[derive(Clone, Copy, PartialEq, Debug)]
enum Saving {
    Saver,
    Balanced,
    Performance,
}

impl Saving {
    fn read() -> Saving {
        Saving::from_profile(
            read_trim(PLATFORM_PROFILE)
                .or_else(|| read_trim(EPP))
                .as_deref(),
        )
    }

    fn from_profile(profile: Option<&str>) -> Saving {
        match profile {
            Some("low-power" | "quiet" | "cool" | "power") => Saving::Saver,
            Some("performance") => Saving::Performance,
            _ => Saving::Balanced,
        }
    }

    // The tiers the mode climbs between, of tiers 0 to top. Saver stays on the
    // lightest: battery first, and a boost for the job that needs more.
    // Performance starts a rung up and never drops below it.
    fn range(self, top: usize) -> (usize, usize) {
        match self {
            Saving::Saver => (0, 0),
            Saving::Balanced => (0, top),
            Saving::Performance => (1.min(top), top),
        }
    }

    // How long the first rung's load has to last; each rung after takes as
    // long again. Performance believes a load four times as soon.
    fn climb_after(self, base: Duration) -> Duration {
        match self {
            Saving::Performance => base / 4,
            _ => base,
        }
    }
}

// The integrated card's frequency knobs. cardN numbering is not stable across
// boots — the same reason the compositor is pinned through a udev symlink
// rather than a path — so the card is found by driver, not by number.
struct IGpu {
    max: PathBuf,
    boost: PathBuf,
    min_mhz: u64,
    hw_max_mhz: u64,
}

impl IGpu {
    fn find() -> Option<IGpu> {
        let dir = fs::read_dir("/sys/class/drm").ok()?;
        for e in dir.flatten() {
            let p = e.path();
            let name = p.file_name()?.to_string_lossy().to_string();
            // "card1", not "card1-eDP-1".
            if !name.starts_with("card") || name.contains('-') {
                continue;
            }
            let Ok(driver) = fs::read_link(p.join("device/driver")) else {
                continue;
            };
            let Some(driver) = driver.file_name() else {
                continue;
            };
            let driver = driver.to_string_lossy().to_string();
            if driver != "i915" && driver != "xe" {
                continue;
            }
            let max = p.join("gt_max_freq_mhz");
            if !max.exists() {
                continue;
            }
            return Some(IGpu {
                boost: p.join("gt_boost_freq_mhz"),
                min_mhz: read_u64(p.join("gt_RPn_freq_mhz")).unwrap_or(0),
                hw_max_mhz: read_u64(p.join("gt_RP0_freq_mhz")).unwrap_or(0),
                max,
            });
        }
        None
    }

    // Order matters when raising: the boost target cannot exceed the ceiling,
    // so the ceiling goes up first and comes down last.
    fn set(&self, w: &mut Writer, mhz: u64) {
        let want = mhz.clamp(self.min_mhz, self.hw_max_mhz.max(mhz));
        let current = read_u64(&self.max).unwrap_or(0);
        if want >= current {
            w.write(&self.max, &want.to_string());
            w.write(&self.boost, &want.to_string());
        } else {
            w.write(&self.boost, &want.to_string());
            w.write(&self.max, &want.to_string());
        }
    }
}

// Whether a charger is in. Reading `online` asks the EC, so the supplies that
// are chargers are found once and read once a poll; they are looked for again
// every minute, for one that appears later, and whenever there is none.
struct Mains {
    online: Vec<PathBuf>,
    found_at: Instant,
}

impl Mains {
    fn new() -> Self {
        Mains {
            online: Self::find(),
            found_at: Instant::now(),
        }
    }

    fn find() -> Vec<PathBuf> {
        let Ok(dir) = fs::read_dir("/sys/class/power_supply") else {
            return Vec::new();
        };
        dir.flatten()
            .map(|e| e.path())
            .filter(|p| read_trim(p.join("type")).as_deref() == Some("Mains"))
            .map(|p| p.join("online"))
            .collect()
    }

    // No charger to ask is a desktop, and a desktop is on AC.
    fn on_ac(&mut self) -> bool {
        if self.online.is_empty() || self.found_at.elapsed() >= Duration::from_secs(60) {
            self.online = Self::find();
            self.found_at = Instant::now();
        }
        if self.online.is_empty() {
            return true;
        }
        self.online
            .iter()
            .any(|p| read_trim(p).as_deref() == Some("1"))
    }
}

fn boosting() -> bool {
    Path::new(BOOST).exists()
}

// ---------------------------------------------------------------- firmware

// What the registers held before this daemon existed, so AC can put back the
// real values rather than the last thing we happened to write. Captured once
// and kept in /run, because a restart with the caps already applied would
// otherwise record 12 W as "what the firmware wanted" and there would be no
// route back short of a reboot.
#[derive(Clone, Copy, Debug)]
struct Firmware {
    pl1_uw: u64,
    pl1_window_us: u64,
    pl2_uw: u64,
    max_pct: u64,
    no_turbo: u64,
    gpu_max_mhz: u64,
    gpu_boost_mhz: u64,
}

impl Firmware {
    fn capture_or_load(igpu: Option<&IGpu>) -> Option<Firmware> {
        if let Some(text) = read_trim(FIRMWARE) {
            let v: Vec<u64> = text
                .split_whitespace()
                .filter_map(|f| f.parse().ok())
                .collect();
            if v.len() >= 4 {
                return Some(Firmware {
                    pl1_uw: v[0],
                    pl1_window_us: v[1],
                    pl2_uw: v[2],
                    max_pct: v[3],
                    no_turbo: v.get(4).copied().unwrap_or(0),
                    gpu_max_mhz: v.get(5).copied().unwrap_or(0),
                    gpu_boost_mhz: v.get(6).copied().unwrap_or(0),
                });
            }
        }
        // The bash half may already have capped these, and reading them now
        // would record its 30 W as what the firmware wanted — after which AC
        // "restores" to the cap and there is no way back short of a reboot.
        // It saves the real values on its way to battery, in exactly the same
        // /run files it uses to restore them, so those come first. Measured
        // the hard way: the first run of this daemon captured PL1 as 30 W on a
        // machine whose firmware value is 109 W.
        let handover = read_trim(BASH_RAPL_STATE).map(|t| {
            t.split_whitespace()
                .filter_map(|f| f.parse::<u64>().ok())
                .collect::<Vec<u64>>()
        });
        let (h_pl1, h_win, h_pl2) = match handover.as_deref() {
            Some([a, b, c, ..]) => (Some(*a), Some(*b), Some(*c)),
            Some([a, b]) => (Some(*a), Some(*b), None),
            _ => (None, None, None),
        };
        let h_pct = read_u64(BASH_PCT_STATE);
        if h_pl1.is_some() || h_pct.is_some() {
            say!("taking the firmware values from nova-power's own saved state");
        }
        let fw = Firmware {
            pl1_uw: h_pl1.or_else(|| read_u64(format!("{RAPL}/constraint_0_power_limit_uw")))?,
            pl1_window_us: h_win
                .or_else(|| read_u64(format!("{RAPL}/constraint_0_time_window_us")))
                .unwrap_or(28_000_000),
            pl2_uw: h_pl2
                .or_else(|| read_u64(format!("{RAPL}/constraint_1_power_limit_uw")))
                .unwrap_or(0),
            max_pct: h_pct.or_else(|| read_u64(PSTATE_MAX)).unwrap_or(100),
            // Never taken from the handover: the bash half has no turbo knob,
            // so whatever is live now is the firmware's own answer.
            no_turbo: read_u64(PSTATE_NO_TURBO).unwrap_or(0),
            gpu_max_mhz: igpu.and_then(|g| read_u64(&g.max)).unwrap_or(0),
            gpu_boost_mhz: igpu.and_then(|g| read_u64(&g.boost)).unwrap_or(0),
        };
        let _ = fs::write(
            FIRMWARE,
            format!(
                "{} {} {} {} {} {} {}\n",
                fw.pl1_uw,
                fw.pl1_window_us,
                fw.pl2_uw,
                fw.max_pct,
                fw.no_turbo,
                fw.gpu_max_mhz,
                fw.gpu_boost_mhz
            ),
        );
        Some(fw)
    }
}

// ---------------------------------------------------------------- the second copy

// On AC this machine's firmware lowers the MMIO copy of PL1 to 30 W after
// about a minute of heavy load, and keeps it there for minutes after the load
// has gone, whatever the MSR copy says. Measured on 2026-11-03, 16 threads on
// AC: 83 W falling to 47 W at the package's 96 °C, then 28 W and 2.7 GHz once
// the copy dropped. The package still guards itself at its TCC temperature,
// so on AC the copy is held at the AC PL1, the firmware's own boot value
// here. On battery the MSR tiers sit below it, and it is left alone; at a stop
// there is nothing to put back, as what it holds is the firmware's number.
struct MmioPl1 {
    path: PathBuf,
    raised: u32,
    said_at: Option<Instant>,
}

impl MmioPl1 {
    fn find() -> Option<MmioPl1> {
        let path = Path::new(RAPL_MMIO).join("constraint_0_power_limit_uw");
        path.exists().then_some(MmioPl1 {
            path,
            raised: 0,
            said_at: None,
        })
    }

    // Read once a poll, written only when lowered. A line the first time and
    // then at most every ten minutes, with the count, so a long build that
    // the firmware keeps lowering does not fill the journal.
    fn hold(&mut self, w: &mut Writer, pl1_uw: u64, now: Instant) {
        let found = read_u64(&self.path);
        if !lowered(found, pl1_uw) || !w.write(&self.path, &pl1_uw.to_string()) {
            return;
        }
        self.raised += 1;
        if self
            .said_at
            .is_none_or(|t| now.duration_since(t) >= Duration::from_secs(600))
        {
            say!(
                "ac: the firmware lowered the MMIO PL1 to {} W; back to {} W ({} since the last line)",
                found.unwrap_or(0) / 1_000_000,
                pl1_uw / 1_000_000,
                self.raised
            );
            self.said_at = Some(now);
            self.raised = 0;
        }
    }
}

// A copy below the firmware's PL1. One the firmware raised above it is left
// as it is, and one that cannot be read is no reason to write.
fn lowered(found: Option<u64>, pl1_uw: u64) -> bool {
    found.is_some_and(|uw| uw < pl1_uw)
}

// ---------------------------------------------------------------- fans

// The EC owns the fans unless told otherwise, and it takes them back on its own
// if this process stops refreshing the watchdog. That ordering is the whole
// safety argument: the failure mode of a dead governor is a machine on the
// EC's own curve, not one that cooks.
struct Fans {
    available: bool,
    level: String,
    last_watchdog: Instant,
}

impl Fans {
    fn new() -> Self {
        // fan_control=0 is the default, and without it every level write is
        // rejected. Saying so once at startup is better than a silent no-op
        // that looks like a curve nobody tuned right.
        let available = Path::new(FAN).exists()
            && read_trim("/sys/module/thinkpad_acpi/parameters/fan_control").as_deref()
                == Some("Y");
        Fans {
            available,
            level: String::new(),
            last_watchdog: Instant::now() - Duration::from_secs(3600),
        }
    }

    fn set(&mut self, w: &mut Writer, level: &str, watchdog_secs: u64) {
        if !self.available {
            return;
        }
        // Refresh first, then set. If the level write fails, the watchdog we
        // just armed is what ends up mattering.
        let mut refreshed = false;
        if self.last_watchdog.elapsed() >= Duration::from_secs(watchdog_secs / 3 + 1)
            && w.write(FAN, &format!("watchdog {watchdog_secs}\n"))
        {
            self.last_watchdog = Instant::now();
            refreshed = true;
        }
        // Re-asserted on every refresh rather than only on change, because the
        // EC silently takes the fans back and our cache would never know: a
        // resume resets it, and so does the watchdog firing. A proc write every
        // ten seconds is cheaper than being wrong about it for an hour.
        if (self.level != level || refreshed) && w.write(FAN, &format!("level {level}\n")) {
            if self.level != level {
                say!("fan level {level}");
            }
            self.level = level.to_string();
        }
    }

    // The fans back to the EC: on the way out, and with no temperature to go by.
    fn release(&mut self, w: &mut Writer) {
        if !self.available || self.level == "auto" {
            return;
        }
        if w.write(FAN, "level auto\n") {
            say!("fan level auto (released to the EC)");
            self.level = "auto".to_string();
        }
    }
}

// A fan level as the EC takes it: 0, still, to 7, and full speed, past 7 and
// unregulated, as fast as the fans go.
const FULL: u8 = 8;

fn level_name(level: u8) -> String {
    if level >= FULL {
        "full-speed".to_string()
    } else {
        level.to_string()
    }
}

// Each level from the temperature it starts at. The EC's own curve stops at
// about 3,600-4,000 rpm with the package held at its 96 °C, short of what the
// fans can do (fact 51). Plugged in, there is no battery to spare: the fans
// are still at rest and reach full speed under any load that lasts.
const AC_CURVE: &[(f64, u8)] = &[
    (55.0, 1),
    (62.0, 2),
    (68.0, 3),
    (74.0, 4),
    (79.0, 5),
    (84.0, 7),
    (88.0, FULL),
];

// On battery, still to 70 °C: a warm chassis is cheaper than a spinning fan,
// which is most of a watt itself, and the tiers keep the package cooler.
const BATTERY_CURVE: &[(f64, u8)] = &[(70.0, 1), (78.0, 2), (84.0, 4), (88.0, 7), (92.0, FULL)];

fn curve_level(curve: &[(f64, u8)], temp: f64) -> u8 {
    curve
        .iter()
        .take_while(|(at, _)| temp >= *at)
        .last()
        .map_or(0, |(_, level)| *level)
}

// The curve, read from the heat the fans can move rather than from every spike.
// A burst takes the package to 90 °C for a second and the heatsink barely
// notices, so the curve reads an average of the last few seconds (the heatsink
// takes about that long to follow): the fans rise as heat builds, not at each
// spike. They come down a level at a time, 3 °C below where the level starts
// and 12 s later, so a build's pauses do not set them hunting. A package
// at its critical temperature for three polls is not a spike: full speed at
// once.
struct FanCurve {
    level: u8,
    average: Option<f64>,
    hot_polls: u32,
    lower_since: Option<Instant>,
}

impl FanCurve {
    const DOWN_AFTER: Duration = Duration::from_secs(12);
    const DOWN_MARGIN: f64 = 3.0;

    fn new() -> Self {
        FanCurve {
            level: 0,
            average: None,
            hot_polls: 0,
            lower_since: None,
        }
    }

    // A resume, or fans the EC has had: start from the heat there is now.
    fn forget(&mut self) {
        self.level = 0;
        self.average = None;
        self.hot_polls = 0;
        self.lower_since = None;
    }

    fn step(&mut self, curve: &[(f64, u8)], temp: f64, critical: f64, now: Instant) -> u8 {
        let average = self.average.map_or(temp, |a| a + (temp - a) * 0.2);
        self.average = Some(average);
        self.hot_polls = if temp >= critical {
            self.hot_polls + 1
        } else {
            0
        };
        if self.hot_polls >= 3 {
            self.level = FULL;
            self.lower_since = None;
            return FULL;
        }
        let want = curve_level(curve, average);
        if want >= self.level || curve_level(curve, average + Self::DOWN_MARGIN) >= self.level {
            self.level = self.level.max(want);
            self.lower_since = None;
            return self.level;
        }
        let since = *self.lower_since.get_or_insert(now);
        if now.duration_since(since) >= Self::DOWN_AFTER {
            // The curve's next level down, or still.
            self.level = curve
                .iter()
                .map(|(_, level)| *level)
                .filter(|level| *level < self.level)
                .max()
                .unwrap_or(0);
            self.lower_since = Some(now);
        }
        self.level
    }
}

// ---------------------------------------------------------------- governor

// PL1 is an average over this window. Plugged in, the PL1 it averages to is
// never reached for long (the package's heat comes first), so this is only
// Intel's own figure for the part.
const AC_WINDOW_US: u64 = 28_000_000;

#[derive(Clone, Copy, PartialEq, Debug)]
enum Mode {
    Ac,
    Battery(usize),
}

struct Governor {
    cfg: Config,
    mode: Mode,
    // How long the load has been above climb / below fall. Only one of these
    // is ever running: they are two views of the same continuous stretch.
    above_since: Option<Instant>,
    below_since: Option<Instant>,
    applied: Option<(u64, u64, u64, bool)>,
    throttled: bool,
}

impl Governor {
    fn new(cfg: Config) -> Self {
        Governor {
            cfg,
            mode: Mode::Ac,
            above_since: None,
            below_since: None,
            applied: None,
            throttled: false,
        }
    }

    // The state machine, and the reason this is a daemon rather than a udev
    // rule. A spike does not climb: it has to hold above the threshold for
    // climb_after, which is longer than any interaction. Falling takes longer
    // still, so the gaps between files in a build do not cost a re-ramp.
    fn step(
        &mut self,
        ac: bool,
        saving: Saving,
        boost: bool,
        busy: f64,
        temp: Option<f64>,
        now: Instant,
    ) -> Mode {
        if ac {
            self.above_since = None;
            self.below_since = None;
            return Mode::Ac;
        }
        // A boost is the user saying "I know what this is, leave it alone".
        if boost {
            self.above_since = None;
            self.below_since = None;
            return Mode::Battery(self.cfg.tiers.len() - 1);
        }
        let (floor, top) = saving.range(self.cfg.tiers.len() - 1);
        let mut tier = match self.mode {
            Mode::Battery(t) => t.clamp(floor, top),
            // Coming off AC always starts at the mode's bottom. Anything else
            // would hand a full tier to whatever happened to be running at
            // unplug.
            Mode::Ac => floor,
        };

        if busy >= self.cfg.busy_climb {
            self.below_since = None;
            let since = *self.above_since.get_or_insert(now);
            // Each rung costs more than the one below it, so "prolonged" means
            // something: 8 s to leave light, 16 s more to reach full, 24 s more
            // to reach turbo — about a minute of unbroken load for the top,
            // which nothing but real work will ever produce.
            let dwell = saving.climb_after(self.cfg.climb_after) * (tier as u32 + 1);
            if now.duration_since(since) >= dwell && tier < top {
                tier += 1;
                self.above_since = Some(now);
                say!(
                    "climbing to {} after {}s of load",
                    self.cfg.tiers[tier].name,
                    dwell.as_secs()
                );
            }
        } else if busy <= self.cfg.busy_fall {
            self.above_since = None;
            let since = *self.below_since.get_or_insert(now);
            if now.duration_since(since) >= self.cfg.fall_after && tier > floor {
                tier -= 1;
                self.below_since = Some(now);
            }
        } else {
            // Between the two thresholds nothing moves. That band is what
            // stops a load hovering near the line from oscillating tiers.
            self.above_since = None;
            self.below_since = None;
        }

        // Temperature outranks load, and the mode's floor. A tier that cannot
        // be cooled is not a tier that was earned, whatever the CPU is busy
        // doing.
        if let Some(t) = temp {
            if t >= self.cfg.temp_throttle && tier > 0 {
                if !self.throttled {
                    say!("package at {t:.0} C — stepping down from tier {tier}");
                }
                self.throttled = true;
                tier -= 1;
                self.above_since = None;
            } else if t < self.cfg.temp_throttle - 5.0 {
                self.throttled = false;
            }
        }
        Mode::Battery(tier)
    }

    fn apply(&mut self, w: &mut Writer, mode: Mode, fw: Firmware, igpu: Option<&IGpu>) {
        let (pl1_uw, pl1_win, pl2_uw, max_pct, no_turbo, label) = match mode {
            // Plugged in: everything, turbo and the whole range, to the
            // limits that are Nova's for AC.
            Mode::Ac => (
                self.cfg.ac_pl1_w * 1_000_000,
                AC_WINDOW_US,
                self.cfg.ac_pl2_w * 1_000_000,
                100,
                false,
                "ac",
            ),
            Mode::Battery(t) => {
                let tier = self.cfg.tiers[t];
                // A short window is half the knob: PL1 is an average, and the
                // firmware's 56 s here lets a burst most of a minute long
                // escape the cap entirely.
                (
                    tier.pl1_w * 1_000_000,
                    10_000_000,
                    tier.pl2_w * 1_000_000,
                    tier.max_pct,
                    tier.no_turbo,
                    tier.name,
                )
            }
        };
        let want = (pl1_uw, pl2_uw, max_pct, no_turbo);
        if self.applied == Some(want) && self.mode == mode {
            return;
        }
        w.write(
            format!("{RAPL}/constraint_0_power_limit_uw"),
            &pl1_uw.to_string(),
        );
        w.write(
            format!("{RAPL}/constraint_0_time_window_us"),
            &pl1_win.to_string(),
        );
        if pl2_uw > 0 {
            w.write(
                format!("{RAPL}/constraint_1_power_limit_uw"),
                &pl2_uw.to_string(),
            );
        }
        // max_perf_pct below min_perf_pct is rejected outright by the driver,
        // so a low tier on a machine with a high floor would silently do
        // nothing at all.
        let floor = read_u64(PSTATE_MIN).unwrap_or(0);
        // Turbo off before the ceiling comes down and back on after it goes up,
        // so there is never a moment where the driver is allowed a P-state the
        // tier we are leaving did not permit.
        if no_turbo {
            w.write(PSTATE_NO_TURBO, "1");
        }
        w.write(PSTATE_MAX, &max_pct.max(floor).to_string());
        if !no_turbo {
            w.write(PSTATE_NO_TURBO, "0");
        }

        // The iGPU spends out of the same package budget, and waitboost will
        // take it to RP0 for a stalled buffer unless the boost target says
        // otherwise. 0 means "leave it to the driver", which is what the top
        // two tiers and AC do.
        if let Some(g) = igpu {
            let want = match mode {
                Mode::Ac => fw.gpu_max_mhz,
                Mode::Battery(t) => {
                    let m = self.cfg.tiers[t].gpu_mhz;
                    if m == 0 {
                        fw.gpu_max_mhz
                    } else {
                        m
                    }
                }
            };
            if want > 0 {
                g.set(w, want);
            }
            // The boost target is the one that actually causes the spikes, so
            // on AC it goes back to whatever it was rather than to the ceiling.
            if matches!(mode, Mode::Ac) && fw.gpu_boost_mhz > 0 {
                w.write(&g.boost, &fw.gpu_boost_mhz.to_string());
            }
        }

        say!(
            "{label}: PL1 {} W over {} s, PL2 {} W, ceiling {}%{}",
            pl1_uw / 1_000_000,
            pl1_win / 1_000_000,
            pl2_uw / 1_000_000,
            max_pct,
            if no_turbo { ", turbo off" } else { "" }
        );
        self.applied = Some(want);
        self.mode = mode;
    }
}

// ---------------------------------------------------------------- main

fn write_state(
    cfg: &Config,
    mode: Mode,
    busy: f64,
    temp: Option<f64>,
    fan: &str,
    watts: Option<f64>,
) {
    let label = match mode {
        Mode::Ac => "ac".to_string(),
        Mode::Battery(t) => format!("battery/{}", cfg.tiers.get(t).map_or("?", |tier| tier.name)),
    };
    let t = temp
        .map(|t| format!("{t:.0}"))
        .unwrap_or_else(|| "?".into());
    let w = watts
        .map(|w| format!("{w:.1}"))
        .unwrap_or_else(|| "?".into());
    let _ = fs::write(STATE, format!("{label} {busy:.0} {t} {fan} {w}\n"));
}

fn main() {
    unsafe {
        signal(SIGTERM, on_signal as *const () as usize);
        signal(SIGINT, on_signal as *const () as usize);
        signal(SIGHUP, on_signal as *const () as usize);
    }

    let mut cfg = Config::load();
    let mut w = Writer::new();

    if !cfg.enabled {
        say!("GOVERNOR=off in {CONFIG} — nothing to do");
        return;
    }
    let igpu = IGpu::find();
    match &igpu {
        Some(g) => say!("integrated GPU: {}-{} MHz", g.min_mhz, g.hw_max_mhz),
        None => say!("no integrated GPU frequency controls found"),
    }
    let Some(fw) = Firmware::capture_or_load(igpu.as_ref()) else {
        eprintln!("no {RAPL} — this is not a machine with an Intel RAPL package domain");
        std::process::exit(1);
    };
    say!(
        "firmware: PL1 {} W over {} s, PL2 {} W, ceiling {}%",
        fw.pl1_uw / 1_000_000,
        fw.pl1_window_us / 1_000_000,
        fw.pl2_uw / 1_000_000,
        fw.max_pct
    );

    let mut fans = Fans::new();
    if cfg.fan_control && !fans.available {
        eprintln!(
            "FAN_CONTROL=on but thinkpad_acpi has fan_control=0 — fans left to the EC. \
             The installer writes the modprobe option; it needs a reboot to take."
        );
    }

    // The marker the bash half checks before touching PL1, PL2 or max_perf_pct.
    // Written after the firmware capture, so a crash between the two does not
    // leave the other half standing down for a daemon that never started.
    let _ = fs::write(OWNS_CPU, "nova-powerd\n");

    let mut sampler = CpuSampler::new();
    let mut meter = PackageMeter::new();
    let mut gov = Governor::new(cfg.clone());
    let mut mains = Mains::new();
    let mut package = PackageTemp::new();
    let mut ec = EcSensors::find();
    let mut curve = FanCurve::new();
    let mut mmio = MmioPl1::find();
    let mut last_ac = mains.on_ac();
    // Instant is CLOCK_MONOTONIC, which does not advance across S3, so the
    // dwell timers correctly ignore time spent asleep. That also means they
    // cannot see a resume — and firmware does reset RAPL across one, while the
    // EC takes the fans back. Wall clock against monotonic is the difference,
    // and a gap much larger than one poll is a suspend by definition.
    let mut last_wall = std::time::SystemTime::now();
    // The first sample covers whatever happened since boot, which is not a
    // measurement of now. Discard it rather than letting it decide a tier.
    let _ = sampler.busy_pct();

    while !STOPPING.load(Ordering::SeqCst) {
        std::thread::sleep(Duration::from_millis(cfg.poll_ms));

        if RELOAD.swap(false, Ordering::SeqCst) {
            cfg = Config::load();
            // Off on a reload as at a start: everything goes back the way a
            // stop puts it, and the exit is a clean one, which the unit does
            // not restart. systemctl start brings it back.
            if !cfg.enabled {
                say!("GOVERNOR=off in {CONFIG} — handing everything back");
                break;
            }
            gov.cfg = cfg.clone();
            gov.applied = None;
            say!("config reloaded");
        }

        let now = Instant::now();

        let wall = std::time::SystemTime::now();
        let slept = wall
            .duration_since(last_wall)
            .map(|d| d > Duration::from_millis(cfg.poll_ms * 4))
            .unwrap_or(false);
        last_wall = wall;
        if slept {
            say!("resumed — re-asserting limits and fan level");
            gov.applied = None;
            gov.above_since = None;
            gov.below_since = None;
            fans.level.clear();
            fans.last_watchdog = Instant::now() - Duration::from_secs(3600);
            curve.forget();
            // The counters did not advance while asleep, so the first sample
            // after a resume describes the moment before it. Throw it away.
            let _ = sampler.busy_pct();
            meter.forget();
            continue;
        }

        let busy = sampler.busy_pct();
        let temp = package.read();
        let watts = meter.watts(now);

        // A plug event is the one transition worth resetting everything for:
        // the dwell timers measured a different machine.
        let ac = mains.on_ac();
        if ac != last_ac {
            gov.above_since = None;
            gov.below_since = None;
            gov.applied = None;
            last_ac = ac;
        }

        let mode = gov.step(ac, Saving::read(), boosting(), busy, temp, now);
        gov.apply(&mut w, mode, fw, igpu.as_ref());
        if let (Mode::Ac, Some(copy)) = (mode, mmio.as_mut()) {
            copy.hold(&mut w, cfg.ac_pl1_w * 1_000_000, now);
        }

        // Fans last. Without the package's own temperature there is nothing to
        // go by, and the EC has its own sensors.
        let fan_label = if !cfg.fan_control || !fans.available {
            "ec".to_string()
        } else if let Some(t) = temp {
            let hottest = ec.hottest(now).map_or(t, |e| e.max(t));
            let shape = if ac { AC_CURVE } else { BATTERY_CURVE };
            let level = curve.step(shape, hottest, cfg.temp_critical, now);
            fans.set(&mut w, &level_name(level), cfg.fan_watchdog_secs);
            if level >= FULL {
                "full".to_string()
            } else {
                level.to_string()
            }
        } else {
            fans.release(&mut w);
            curve.forget();
            "ec/blind".to_string()
        };

        write_state(&cfg, mode, busy, temp, &fan_label, watts);
    }

    // On the way out, put everything back. systemd also has an ExecStopPost for
    // the case where this never runs, and the EC's watchdog covers the case
    // where neither does.
    say!("stopping: restoring firmware limits and releasing the fans");
    fans.release(&mut w);
    w.write(
        format!("{RAPL}/constraint_0_power_limit_uw"),
        &fw.pl1_uw.to_string(),
    );
    w.write(
        format!("{RAPL}/constraint_0_time_window_us"),
        &fw.pl1_window_us.to_string(),
    );
    if fw.pl2_uw > 0 {
        w.write(
            format!("{RAPL}/constraint_1_power_limit_uw"),
            &fw.pl2_uw.to_string(),
        );
    }
    w.write(PSTATE_MAX, &fw.max_pct.to_string());
    w.write(PSTATE_NO_TURBO, &fw.no_turbo.to_string());
    if let Some(g) = &igpu {
        if fw.gpu_max_mhz > 0 {
            g.set(&mut w, fw.gpu_max_mhz);
        }
        if fw.gpu_boost_mhz > 0 {
            w.write(&g.boost, &fw.gpu_boost_mhz.to_string());
        }
    }
    let _ = fs::remove_file(OWNS_CPU);
    let _ = fs::remove_file(STATE);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn watts_are_energy_over_time() {
        let w = watts_between(1_000_000, 13_000_000, 0, Duration::from_secs(2));
        assert_eq!(w, Some(6.0));
    }

    #[test]
    fn a_wrapped_counter_counts_across_the_wrap() {
        let w = watts_between(
            990_000_000,
            4_000_000,
            1_000_000_000,
            Duration::from_secs(1),
        );
        assert_eq!(w, Some(14.0));
    }

    #[test]
    fn only_a_copy_below_the_firmware_pl1_is_raised() {
        assert!(lowered(Some(30_000_000), 109_000_000));
        assert!(!lowered(Some(109_000_000), 109_000_000));
        assert!(!lowered(Some(120_000_000), 109_000_000));
        assert!(!lowered(None, 109_000_000));
    }

    #[test]
    fn a_counter_that_went_back_without_a_range_is_no_reading() {
        assert_eq!(watts_between(5, 4, 0, Duration::from_secs(1)), None);
        assert_eq!(watts_between(1, 2, 0, Duration::ZERO), None);
    }

    // A governor stepped once a second for <secs> at <busy> percent, cool.
    fn run(gov: &mut Governor, saving: Saving, busy: f64, secs: u64, from: Instant) -> Mode {
        let mut mode = gov.mode;
        for i in 0..secs {
            mode = gov.step(
                false,
                saving,
                false,
                busy,
                Some(60.0),
                from + Duration::from_secs(i),
            );
            gov.mode = mode;
        }
        mode
    }

    #[test]
    fn the_profile_names_the_battery_mode() {
        assert_eq!(Saving::from_profile(Some("low-power")), Saving::Saver);
        assert_eq!(Saving::from_profile(Some("power")), Saving::Saver);
        assert_eq!(Saving::from_profile(Some("balanced")), Saving::Balanced);
        assert_eq!(
            Saving::from_profile(Some("balance_power")),
            Saving::Balanced
        );
        assert_eq!(
            Saving::from_profile(Some("performance")),
            Saving::Performance
        );
        assert_eq!(Saving::from_profile(None), Saving::Balanced);
    }

    #[test]
    fn saver_stays_light_under_any_load() {
        let mut gov = Governor::new(Config::default());
        assert_eq!(
            run(&mut gov, Saving::Saver, 100.0, 300, Instant::now()),
            Mode::Battery(0)
        );
    }

    #[test]
    fn balanced_climbs_the_whole_ladder_in_about_a_minute() {
        let mut gov = Governor::new(Config::default());
        let now = Instant::now();
        assert_eq!(
            run(&mut gov, Saving::Balanced, 100.0, 40, now),
            Mode::Battery(2)
        );
        assert_eq!(
            run(
                &mut gov,
                Saving::Balanced,
                100.0,
                40,
                now + Duration::from_secs(40)
            ),
            Mode::Battery(3)
        );
    }

    #[test]
    fn performance_starts_a_rung_up_and_climbs_four_times_as_fast() {
        let mut gov = Governor::new(Config::default());
        let now = Instant::now();
        assert_eq!(
            run(&mut gov, Saving::Performance, 0.0, 120, now),
            Mode::Battery(1)
        );
        // 4 s to full and 6 s more to turbo, against 16 and 24.
        assert_eq!(
            run(
                &mut gov,
                Saving::Performance,
                100.0,
                12,
                now + Duration::from_secs(120)
            ),
            Mode::Battery(3)
        );
    }

    #[test]
    fn a_boost_and_ac_outrank_the_mode() {
        let mut gov = Governor::new(Config::default());
        let now = Instant::now();
        assert_eq!(
            gov.step(false, Saving::Saver, true, 0.0, Some(50.0), now),
            Mode::Battery(3)
        );
        assert_eq!(
            gov.step(true, Saving::Saver, false, 0.0, Some(50.0), now),
            Mode::Ac
        );
    }

    // A curve stepped once a second at each temperature in turn.
    fn heat(curve: &mut FanCurve, shape: &[(f64, u8)], temps: &[f64], from: Instant) -> Vec<u8> {
        temps
            .iter()
            .enumerate()
            .map(|(i, t)| curve.step(shape, *t, 92.0, from + Duration::from_secs(i as u64)))
            .collect()
    }

    #[test]
    fn a_second_long_spike_does_not_spin_the_fans() {
        let mut curve = FanCurve::new();
        let levels = heat(
            &mut curve,
            AC_CURVE,
            &[45.0, 45.0, 90.0, 45.0, 45.0],
            Instant::now(),
        );
        assert_eq!(levels, [0, 0, 0, 0, 0]);
    }

    #[test]
    fn plugged_in_a_load_that_lasts_reaches_full_speed() {
        let mut curve = FanCurve::new();
        // Under critical: the average climbs, in about 17 s to where full
        // speed starts. A package held at its 96 °C gets there in three.
        let temps: Vec<f64> = [45.0].into_iter().chain([89.0; 20]).collect();
        let levels = heat(&mut curve, AC_CURVE, &temps, Instant::now());
        assert_eq!(levels[1], 0);
        assert!(levels.windows(2).all(|w| w[1] >= w[0]), "{levels:?}");
        assert_eq!(*levels.last().unwrap(), FULL);
    }

    #[test]
    fn a_critical_package_for_three_polls_is_full_speed_at_once() {
        let mut curve = FanCurve::new();
        let levels = heat(
            &mut curve,
            BATTERY_CURVE,
            &[40.0, 95.0, 95.0, 95.0],
            Instant::now(),
        );
        assert_eq!(levels, [0, 0, 0, FULL]);
    }

    #[test]
    fn the_fans_come_down_a_level_at_a_time_once_cool_for_twelve_seconds() {
        let mut curve = FanCurve::new();
        let now = Instant::now();
        heat(&mut curve, AC_CURVE, &[95.0; 4], now);
        assert_eq!(curve.level, FULL);
        let levels = heat(
            &mut curve,
            AC_CURVE,
            &[40.0; 40],
            now + Duration::from_secs(4),
        );
        // The average takes a few seconds to fall past full's start, then 12 s
        // a step: 7, then 5.
        assert_eq!(levels[..10], [FULL; 10]);
        assert!(levels.contains(&7) && levels.contains(&5), "{levels:?}");
        assert_eq!(levels.iter().filter(|l| **l == 7).count(), 12);
    }

    #[test]
    fn near_a_level_s_start_the_fans_hold() {
        let mut curve = FanCurve::new();
        let now = Instant::now();
        heat(&mut curve, AC_CURVE, &[75.0; 30], now);
        assert_eq!(curve.level, 4);
        // 2 °C under where level 4 starts, for a minute: within the margin.
        let levels = heat(
            &mut curve,
            AC_CURVE,
            &[72.0; 60],
            now + Duration::from_secs(30),
        );
        assert!(levels.iter().all(|l| *l == 4), "{levels:?}");
    }

    #[test]
    fn the_ec_s_empty_sensors_are_no_reading() {
        assert_eq!(ec_celsius(0), None);
        assert_eq!(ec_celsius(-128_000), None);
        assert_eq!(ec_celsius(41_000), Some(41.0));
    }
}
