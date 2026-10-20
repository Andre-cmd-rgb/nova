// thinkpad-powerd — the continuous half of thinkpad-power.
//
// thinkpad-power itself is edge-triggered: it runs on a plug event, at boot and
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
// So: three tiers on battery, a dwell time before climbing, a longer one before
// falling, and the fans kept off the case rather than curved. The temperature
// guard outranks the load state, and the fan watchdog outranks everything —
// if this process dies the EC has the fans back within thirty seconds without
// anyone having to notice.
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

const CONFIG: &str = "/etc/thinkpad-power.conf";
const RAPL: &str = "/sys/class/powercap/intel-rapl:0";
const PSTATE_MAX: &str = "/sys/devices/system/cpu/intel_pstate/max_perf_pct";
const PSTATE_MIN: &str = "/sys/devices/system/cpu/intel_pstate/min_perf_pct";
const PSTATE_NO_TURBO: &str = "/sys/devices/system/cpu/intel_pstate/no_turbo";
const FAN: &str = "/proc/acpi/ibm/fan";
// The bash half checks for this before touching PL1, PL2 or max_perf_pct. Two
// things writing the same register is how the power profiles were lost the
// first time round; this is the same hazard with a file in front of it.
const OWNS_CPU: &str = "/run/thinkpad-powerd.owns-cpu";
// What the firmware had before anything here ran. Persisted because a daemon
// restart would otherwise record our own capped values as the originals and
// there would be no way back to the real ones without a reboot.
const FIRMWARE: &str = "/run/thinkpad-powerd.firmware";
// One line, for `thinkpad-power status`.
const STATE: &str = "/run/thinkpad-powerd.state";
// Written by `thinkpad-power boost`. Shared with the bash half deliberately:
// one boost, one file, whichever half is asked.
const BOOST: &str = "/run/thinkpad-power.boost";
// The bash half's own save files. If it capped the registers before this
// started, these hold what the firmware actually had — which is the only
// honest source for "restore everything" on AC.
const BASH_RAPL_STATE: &str = "/run/thinkpad-power.rapl";
const BASH_PCT_STATE: &str = "/run/thinkpad-power.cpupct";

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
    // Above this the fans go back to the EC, whatever the fan policy says.
    temp_critical: f64,
    fan_control: bool,
    // Battery fan curve: (temp to switch this level on, level). The EC's own
    // curve is the fallback and `auto` is always a legal level.
    fan_curve: Vec<(f64, &'static str)>,
    fan_watchdog_secs: u64,
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
            fan_curve: vec![
                // Deliberately lazier than the EC below 70 C: on battery a
                // warm chassis is cheaper than a spinning fan, and the fan
                // itself is most of a watt.
                (0.0, "0"),
                (70.0, "1"),
                (78.0, "2"),
                (84.0, "auto"),
            ],
            fan_watchdog_secs: 30,
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

// The hottest thing that speaks for the package. x86_pkg_temp is the one that
// matters and it is a thermal zone rather than an hwmon here, so it is found by
// type rather than by a path that renumbers.
fn package_temp() -> Option<f64> {
    let mut best: Option<f64> = None;
    if let Ok(dir) = fs::read_dir("/sys/class/thermal") {
        for e in dir.flatten() {
            let p = e.path();
            let Some(kind) = read_trim(p.join("type")) else {
                continue;
            };
            if kind != "x86_pkg_temp" && kind != "TCPU" {
                continue;
            }
            if let Some(mc) = read_u64(p.join("temp")) {
                let c = mc as f64 / 1000.0;
                best = Some(best.map_or(c, |b: f64| b.max(c)));
            }
        }
    }
    best
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
            let driver = fs::read_link(p.join("device/driver")).ok()?;
            let driver = driver.file_name()?.to_string_lossy().to_string();
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

fn on_ac() -> bool {
    let Ok(dir) = fs::read_dir("/sys/class/power_supply") else {
        return true;
    };
    for e in dir.flatten() {
        let p = e.path();
        if read_trim(p.join("type")).as_deref() == Some("Mains")
            && read_trim(p.join("online")).as_deref() == Some("1")
        {
            return true;
        }
    }
    false
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
            say!("taking the firmware values from thinkpad-power's own saved state");
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

// ---------------------------------------------------------------- fans

// The EC owns the fans unless told otherwise, and it takes them back on its own
// if this process stops refreshing the watchdog. That ordering is the whole
// safety argument: the failure mode of a dead governor is a machine that is
// merely as loud as Lenovo intended, not one that cooks.
struct Fans {
    available: bool,
    engaged: bool,
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
            engaged: false,
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
            self.engaged = level != "auto";
        }
    }

    // Unconditional hand-back, used on the way out and whenever the package is
    // hotter than any curve should be arguing about.
    fn release(&mut self, w: &mut Writer) {
        if !self.available || self.level == "auto" {
            return;
        }
        if w.write(FAN, "level auto\n") {
            say!("fan level auto (released to the EC)");
            self.level = "auto".to_string();
            self.engaged = false;
        }
    }

    fn pick(curve: &[(f64, &'static str)], temp: f64) -> &'static str {
        let mut chosen = "auto";
        for (at, level) in curve {
            if temp >= *at {
                chosen = level;
            }
        }
        chosen
    }
}

// ---------------------------------------------------------------- governor

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
    fn step(&mut self, busy: f64, temp: Option<f64>, now: Instant) -> Mode {
        if on_ac() {
            self.above_since = None;
            self.below_since = None;
            return Mode::Ac;
        }
        // A boost is the user saying "I know what this is, leave it alone".
        if boosting() {
            self.above_since = None;
            self.below_since = None;
            return Mode::Battery(self.cfg.tiers.len() - 1);
        }
        let top = self.cfg.tiers.len() - 1;
        let mut tier = match self.mode {
            Mode::Battery(t) => t.min(top),
            // Coming off AC always starts at the bottom. Anything else would
            // hand a full tier to whatever happened to be running at unplug.
            Mode::Ac => 0,
        };

        if busy >= self.cfg.busy_climb {
            self.below_since = None;
            let since = *self.above_since.get_or_insert(now);
            // Each rung costs more than the one below it, so "prolonged" means
            // something: 8 s to leave light, 16 s more to reach full, 24 s more
            // to reach turbo — about a minute of unbroken load for the top,
            // which nothing but real work will ever produce.
            let dwell = self.cfg.climb_after * (tier as u32 + 1);
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
            if now.duration_since(since) >= self.cfg.fall_after && tier > 0 {
                tier -= 1;
                self.below_since = Some(now);
            }
        } else {
            // Between the two thresholds nothing moves. That band is what
            // stops a load hovering near the line from oscillating tiers.
            self.above_since = None;
            self.below_since = None;
        }

        // Temperature outranks load. A tier that cannot be cooled is not a
        // tier that was earned, whatever the CPU is busy doing.
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
            // "Restore everything" on AC means the firmware's own numbers, not
            // a tier of ours that happens to be generous.
            Mode::Ac => (
                fw.pl1_uw,
                fw.pl1_window_us,
                fw.pl2_uw,
                fw.max_pct,
                fw.no_turbo == 1,
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

fn write_state(mode: Mode, busy: f64, temp: Option<f64>, fan: &str) {
    let label = match mode {
        Mode::Ac => "ac".to_string(),
        Mode::Battery(t) => format!("battery/{t}"),
    };
    let t = temp
        .map(|t| format!("{t:.0}"))
        .unwrap_or_else(|| "?".into());
    let _ = fs::write(STATE, format!("{label} {busy:.0} {t} {fan}\n"));
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
    let _ = fs::write(OWNS_CPU, "thinkpad-powerd\n");

    let mut sampler = CpuSampler::new();
    let mut gov = Governor::new(cfg.clone());
    let mut last_ac = on_ac();
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
            // The counters did not advance while asleep, so the first sample
            // after a resume describes the moment before it. Throw it away.
            let _ = sampler.busy_pct();
            continue;
        }

        let busy = sampler.busy_pct();
        let temp = package_temp();

        // A plug event is the one transition worth resetting everything for:
        // the dwell timers measured a different machine.
        let ac = on_ac();
        if ac != last_ac {
            gov.above_since = None;
            gov.below_since = None;
            gov.applied = None;
            last_ac = ac;
        }

        let mode = gov.step(busy, temp, now);
        gov.apply(&mut w, mode, fw, igpu.as_ref());

        // Fans last, and temperature-first. The critical hand-back is checked
        // before the curve is consulted at all, so there is no arrangement of
        // curve entries that can hold a low level on a hot package.
        let fan_label = if !cfg.fan_control || !fans.available {
            "ec"
        } else {
            match (mode, temp) {
                (_, Some(t)) if t >= cfg.temp_critical => {
                    fans.release(&mut w);
                    "ec/hot"
                }
                // On AC the EC's own curve is the right one: there is no
                // battery to save and headroom is worth more than quiet.
                (Mode::Ac, _) => {
                    fans.set(&mut w, "auto", cfg.fan_watchdog_secs);
                    "auto"
                }
                (Mode::Battery(_), Some(t)) => {
                    let level = Fans::pick(&cfg.fan_curve, t);
                    fans.set(&mut w, level, cfg.fan_watchdog_secs);
                    if level == "auto" {
                        "auto"
                    } else {
                        "held"
                    }
                }
                // No temperature is not a reason to guess.
                (Mode::Battery(_), None) => {
                    fans.release(&mut w);
                    "ec/blind"
                }
            }
        };

        write_state(mode, busy, temp, fan_label);
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
