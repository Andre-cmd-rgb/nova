// ---------------------------------------------------------------- inputs

use std::fs;
use std::io::Write;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use crate::paths::RAPL;
use crate::sysfs::{read_trim, read_u64, say};

// Busy percent across every CPU, from the aggregate line of /proc/stat. iowait
// is not busy: a build waiting on the NVMe is not asking for frequency, and
// counting it would unlock the caps for something the CPU is not doing.
pub(crate) struct CpuSampler {
    last_busy: u64,
    last_total: u64,
}

impl CpuSampler {
    pub(crate) fn new() -> Self {
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

    pub(crate) fn busy_pct(&mut self) -> f64 {
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
pub(crate) struct PackageMeter {
    range_uj: u64,
    last: Option<(u64, Instant)>,
}

impl PackageMeter {
    pub(crate) fn new() -> Self {
        PackageMeter {
            range_uj: read_u64(format!("{RAPL}/max_energy_range_uj")).unwrap_or(0),
            last: None,
        }
    }

    // None for the first reading, and after forget(): one reading is no rate.
    pub(crate) fn watts(&mut self, now: Instant) -> Option<f64> {
        let Some(uj) = read_u64(format!("{RAPL}/energy_uj")) else {
            self.last = None;
            return None;
        };
        let (was, then) = self.last.replace((uj, now))?;
        watts_between(was, uj, self.range_uj, now.duration_since(then))
    }

    // A resume: firmware resets the counter across one.
    pub(crate) fn forget(&mut self) {
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
pub(crate) struct PackageTemp {
    zone: Option<PathBuf>,
}

impl PackageTemp {
    pub(crate) fn new() -> Self {
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

    pub(crate) fn read(&mut self) -> Option<f64> {
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
// spoil. Each read is two of the EC's interrupts (fact 56), so they are read
// every few seconds while anything is warm, every fifteen otherwise, and the
// hottest kept between.
pub(crate) struct EcSensors {
    inputs: Vec<PathBuf>,
    pub(crate) reading: Option<f64>,
    read_at: Option<Instant>,
}

// The driver answers ENXIO for a sensor that reads "not available". The two
// it names (temp1 "CPU", temp2 "GPU") are kept whatever they answer at the
// start: the GPU's is ENXIO for as long as the card sleeps. An unnamed one
// that has nothing at the start is a slot with no sensor behind it, and
// asking for it costs as much as asking for a real one.
const ENXIO: i32 = 6;

fn worth_reading(first: &std::io::Result<String>, named: bool) -> bool {
    named || !matches!(first, Err(e) if e.raw_os_error() == Some(ENXIO))
}

// How long the EC's reading may stand. The package's own sensor is read every
// poll for nothing; the EC's are there for the heat the package does not see,
// the discrete GPU's above all, which matters once something is warm. Warm
// is the fans turning, or the package or the last EC reading within a few
// degrees of where the curve starts.
const EC_FAST: Duration = Duration::from_secs(3);
const EC_SLOW: Duration = Duration::from_secs(15);
const EC_WARM_MARGIN: f64 = 5.0;

pub(crate) fn ec_interval(
    curve: &[(f64, u8)],
    level: u8,
    package: f64,
    ec: Option<f64>,
) -> Duration {
    let warm_at = curve.first().map_or(0.0, |(at, _)| at - EC_WARM_MARGIN);
    if level > 0 || package >= warm_at || ec.is_some_and(|e| e >= warm_at) {
        EC_FAST
    } else {
        EC_SLOW
    }
}

impl EcSensors {
    pub(crate) fn find() -> EcSensors {
        let mut inputs = Vec::new();
        let mut empty = Vec::new();
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
                if !input.exists() {
                    continue;
                }
                let named = p.join(format!("temp{i}_label")).exists();
                if worth_reading(&fs::read_to_string(&input), named) {
                    inputs.push(input);
                } else {
                    empty.push(format!("temp{i}"));
                }
            }
        }
        if !empty.is_empty() {
            say!(
                "EC sensors with nothing behind them, not read: {}",
                empty.join(" ")
            );
        }
        EcSensors {
            inputs,
            reading: None,
            read_at: None,
        }
    }

    // A resume: what the board was before it is no reading of now.
    pub(crate) fn forget(&mut self) {
        self.read_at = None;
    }

    pub(crate) fn hottest(&mut self, now: Instant, every: Duration) -> Option<f64> {
        if self.read_at.is_none_or(|t| now.duration_since(t) >= every) {
            self.read_at = Some(now);
            self.reading = self
                .inputs
                .iter()
                .filter_map(|p| read_trim(p)?.parse::<i64>().ok())
                .filter_map(ec_celsius)
                .reduce(f64::max);
        }
        self.reading
    }
}

// A sensor the EC has nothing for reads 0, or -128 °C.
fn ec_celsius(mc: i64) -> Option<f64> {
    (mc > 0 && mc < 128_000).then(|| mc as f64 / 1000.0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fans::{AC_CURVE, BATTERY_CURVE};
    use crate::tests::scratch;

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
    fn a_counter_that_went_back_without_a_range_is_no_reading() {
        assert_eq!(watts_between(5, 4, 0, Duration::from_secs(1)), None);
        assert_eq!(watts_between(1, 2, 0, Duration::ZERO), None);
    }

    #[test]
    fn the_ec_s_empty_sensors_are_no_reading() {
        assert_eq!(ec_celsius(0), None);
        assert_eq!(ec_celsius(-128_000), None);
        assert_eq!(ec_celsius(41_000), Some(41.0));
    }

    #[test]
    fn an_unnamed_sensor_with_nothing_at_the_start_is_not_read_again() {
        let enxio = || Err(std::io::Error::from_raw_os_error(ENXIO));
        assert!(!worth_reading(&enxio(), false));
        // The GPU's, named, answers ENXIO while the card sleeps.
        assert!(worth_reading(&enxio(), true));
        assert!(worth_reading(&Ok("38000\n".into()), false));
        assert!(worth_reading(&Ok("0\n".into()), false));
        // Any other failure is not the driver saying there is nothing there.
        assert!(worth_reading(
            &Err(std::io::Error::from_raw_os_error(5)),
            false
        ));
    }

    #[test]
    fn the_ec_is_asked_seldom_while_all_is_cool() {
        // Idle: the package at 45 °C, the board at 40, the fans still.
        assert_eq!(ec_interval(AC_CURVE, 0, 45.0, Some(40.0)), EC_SLOW);
        assert_eq!(ec_interval(BATTERY_CURVE, 0, 60.0, Some(55.0)), EC_SLOW);
        assert_eq!(ec_interval(BATTERY_CURVE, 0, 45.0, None), EC_SLOW);
    }

    #[test]
    fn the_ec_is_asked_every_few_seconds_once_anything_is_warm() {
        // The package near where the curve starts, plugged in and not.
        assert_eq!(ec_interval(AC_CURVE, 0, 50.0, Some(40.0)), EC_FAST);
        assert_eq!(ec_interval(BATTERY_CURVE, 0, 66.0, Some(40.0)), EC_FAST);
        // The fans turning, whatever the package says.
        assert_eq!(ec_interval(BATTERY_CURVE, 1, 45.0, Some(40.0)), EC_FAST);
        // The last EC reading warm: the discrete GPU, with the package cool.
        assert_eq!(ec_interval(AC_CURVE, 0, 45.0, Some(60.0)), EC_FAST);
    }

    #[test]
    fn an_ec_reading_stands_for_as_long_as_it_is_let() {
        let dir = scratch("ec");
        let input = dir.join("temp1_input");
        fs::write(&input, "40000\n").unwrap();
        let mut ec = EcSensors {
            inputs: vec![input.clone()],
            reading: None,
            read_at: None,
        };
        let now = Instant::now();
        assert_eq!(ec.hottest(now, EC_SLOW), Some(40.0));
        fs::write(&input, "80000\n").unwrap();
        assert_eq!(
            ec.hottest(now + Duration::from_secs(5), EC_SLOW),
            Some(40.0)
        );
        // Warm now: three seconds is all a reading stands.
        assert_eq!(
            ec.hottest(now + Duration::from_secs(5), EC_FAST),
            Some(80.0)
        );
        fs::write(&input, "50000\n").unwrap();
        ec.forget();
        assert_eq!(
            ec.hottest(now + Duration::from_secs(6), EC_SLOW),
            Some(50.0)
        );
        let _ = fs::remove_dir_all(dir);
    }
}
