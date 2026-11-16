// ---------------------------------------------------------------- config

use std::collections::HashMap;
use std::fs;
use std::time::Duration;

use crate::paths::CONFIG;

#[derive(Clone, Debug)]
pub(crate) struct Config {
    pub(crate) poll_ms: u64,
    // Tiers, battery only. AC restores firmware and gets out of the way.
    pub(crate) tiers: Vec<Tier>,
    // Percent busy across all CPUs that counts as work worth unlocking for,
    // and the quieter figure that counts as done.
    pub(crate) busy_climb: f64,
    pub(crate) busy_fall: f64,
    // The whole point: a spike has to persist to be believed.
    pub(crate) climb_after: Duration,
    pub(crate) fall_after: Duration,
    // Above this the load state stops mattering.
    pub(crate) temp_throttle: f64,
    // Above this for three polls the fans go to full speed, whatever the
    // curve says.
    pub(crate) temp_critical: f64,
    pub(crate) fan_control: bool,
    pub(crate) fan_watchdog_secs: u64,
    // Plugged in, in watts: the most the package may draw, held in both
    // copies. Its heat, not these, is what limits it there.
    pub(crate) ac_pl1_w: u64,
    pub(crate) ac_pl2_w: u64,
    pub(crate) enabled: bool,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct Tier {
    pub(crate) name: &'static str,
    pub(crate) pl1_w: u64,
    pub(crate) pl2_w: u64,
    pub(crate) max_pct: u64,
    // Turbo off outright, rather than only unreachable via the ceiling. A
    // ceiling below the base ratio already prevents it, but this says so to
    // the driver instead of implying it, and it is the knob people look for.
    pub(crate) no_turbo: bool,
    // The iGPU's own ceiling, in MHz. 0 leaves it to the driver.
    //
    // This is the other half of the package budget and it is easy to miss:
    // intel-rapl:0 covers core *and* uncore, and the iGPU spends out of the
    // same watts. Measured here with a windowed 4K YouTube playing, the iGPU
    // sat at 1100-1200 MHz against a 350 MHz floor — to composite a desktop,
    // not to decode anything. i915's waitboost is why: a client stalling on a
    // buffer boosts the GPU to gt_boost_freq_mhz, which ships at RP0.
    pub(crate) gpu_mhz: u64,
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
    pub(crate) fn load() -> Self {
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
