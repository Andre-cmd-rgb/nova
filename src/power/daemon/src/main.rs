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

mod config;
mod fans;
mod firmware;
mod governor;
mod inputs;
mod modes;
mod paths;
mod sysfs;

use std::fs;
use std::io::Write;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use config::Config;
use fans::{level_name, FanCurve, Fans, AC_CURVE, BATTERY_CURVE, FULL};
use firmware::{Firmware, MmioPl1};
use governor::{Governor, Mode};
use inputs::{ec_interval, CpuSampler, EcSensors, PackageMeter, PackageTemp};
use modes::{boosting, IGpu, Mains, Saving};
use paths::{CONFIG, OWNS_CPU, PSTATE_MAX, PSTATE_NO_TURBO, RAPL, STATE};
use sysfs::{say, Writer};

// A few symbols, declared rather than depended on. Rust links libc on this
// target anyway, so a crate for it would be a supply chain for nothing.
extern "C" {
    fn signal(sig: i32, handler: usize) -> usize;
    fn clock_gettime(clock: i32, time: *mut Timespec) -> i32;
}
const SIGTERM: i32 = 15;
const SIGINT: i32 = 2;
const SIGHUP: i32 = 1;

// x86-64's struct timespec.
#[repr(C)]
struct Timespec {
    seconds: i64,
    nanoseconds: i64,
}
const CLOCK_MONOTONIC: i32 = 1;
const CLOCK_BOOTTIME: i32 = 7;

/// How long the computer has slept since it started: the boot clock goes on
/// through a suspend, the monotonic one stands still. Unlike the wall clock,
/// neither is moved by a time server.
fn slept_so_far() -> Duration {
    let read = |clock| {
        let mut time = Timespec {
            seconds: 0,
            nanoseconds: 0,
        };
        // SAFETY: a valid pointer to a timespec, which is all it writes.
        if unsafe { clock_gettime(clock, &mut time) } != 0 {
            return Duration::ZERO;
        }
        Duration::new(
            time.seconds.max(0) as u64,
            time.nanoseconds.clamp(0, 999_999_999) as u32,
        )
    };
    read(CLOCK_BOOTTIME).saturating_sub(read(CLOCK_MONOTONIC))
}

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
    let mut last_ac = mains.on_ac(Instant::now());
    // Instant is CLOCK_MONOTONIC, which does not advance across S3, so the
    // dwell timers correctly ignore time spent asleep. That also means they
    // cannot see a resume — and firmware does reset RAPL across one, while the
    // EC takes the fans back. Wall clock against monotonic is the difference,
    // and a gap much larger than one poll is a suspend by definition.
    let mut last_slept = slept_so_far();
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

        // A sleep of any length, a second's as well as a night's: the
        // firmware may have put its own limits back meanwhile.
        let asleep = slept_so_far();
        let slept = asleep.saturating_sub(last_slept) > Duration::from_millis(500);
        last_slept = asleep;
        if slept {
            say!("resumed — re-asserting limits and fan level");
            gov.applied = None;
            gov.above_since = None;
            gov.below_since = None;
            fans.level.clear();
            fans.last_watchdog = Instant::now() - Duration::from_secs(3600);
            curve.forget();
            ec.forget();
            mains.forget();
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
        let ac = mains.on_ac(now);
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
            let shape = if ac { AC_CURVE } else { BATTERY_CURVE };
            let every = ec_interval(shape, curve.level, t, ec.reading);
            let hottest = ec.hottest(now, every).map_or(t, |e| e.max(t));
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
    use std::path::PathBuf;

    #[test]
    fn awake_the_time_slept_stands_still() {
        let before = slept_so_far();
        std::thread::sleep(Duration::from_millis(50));
        assert!(slept_so_far().saturating_sub(before) < Duration::from_millis(500));
    }

    // A scratch folder of its own for each test that reads files.
    pub(crate) fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("nova-powerd-{}-{name}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }
}
