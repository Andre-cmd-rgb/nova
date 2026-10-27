//! nova-undervolt: lowers an Intel CPU's voltage by the offset chosen with
//! `nova power undervolt set`, and takes it off again by itself whenever it
//! may not be safe.
//!
//! An offset that is too deep does not fail cleanly: the CPU computes wrong
//! answers, logs machine checks, or freezes. So:
//! - before the offset is written, `armed` records it on disk with this
//!   boot's id, and a clean shutdown (the unit's stop) takes the offset off
//!   and removes the record. A boot that finds another boot's record knows
//!   that one ended without shutting down while undervolted, and holds the
//!   offset instead of applying it, so a bad one cannot freeze every boot;
//! - `watch` reads the kernel's log while it is on, and the first machine
//!   check takes it off and holds it;
//! - a hold lasts until somebody applies the offset again, and says why.
//!
//! The firmware has to allow it at all: on most laptops its Overclocking Lock
//! makes the CPU discard every offset, so each one is read back.
//!
//! Commands (root, but status):
//!   run              the service: the offset onto the CPU (or a hold), then
//!                    off at the first machine check
//!   reset            the service's stop: the offset off
//!   reapply          after sleep, which can lose it (a hibernate is a power cycle)
//!   status [--json]  what is set and what the CPU has; the CPU's own
//!                    registers only as root
//!
//! State, in /var/lib/nova/undervolt/: `offset` (whole millivolts, written by
//! nova-power-undervolt-apply: "-70" for the core and cache both, "-80 -70"
//! for the core and the cache each), `armed` ("<boot id> <offset>"), and
//! `held` (why it is held).

mod mailbox;

use mailbox::{CpuMsr, Msr, PLANES};
use std::fmt;
use std::fs::{self, File};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::process::ExitCode;

/// The deepest offset taken. Tiger Lake parts give out well before it: on a
/// P1 Gen 4i, -80 mV logged machine checks (docs/hardware, fact 16).
const DEEPEST: i32 = -150;

const LOCKED: &str = "the firmware's Overclocking Lock is on, so the CPU discards any offset \
(on a ThinkPad it is in the hidden Advanced menu, under CPU Lock Configuration)";

struct Paths {
    state: PathBuf,
    boot_id: PathBuf,
    cpuinfo: PathBuf,
}

impl Paths {
    fn system() -> Paths {
        Paths {
            state: PathBuf::from("/var/lib/nova/undervolt"),
            boot_id: PathBuf::from("/proc/sys/kernel/random/boot_id"),
            cpuinfo: PathBuf::from("/proc/cpuinfo"),
        }
    }

    fn file(&self, name: &str) -> PathBuf {
        self.state.join(name)
    }
}

type Open<'a> = &'a mut dyn FnMut() -> io::Result<Box<dyn Msr>>;

/// An undervolt: the core's offset and the cache's, in whole millivolts,
/// each from DEEPEST to 0 and not both 0.
#[derive(Clone, Copy, PartialEq, Debug)]
struct Offsets {
    core: i32,
    cache: i32,
}

impl Offsets {
    /// "-70", the core and cache both, or "-80 -70", the core and the cache.
    fn parse(text: &str) -> Option<Offsets> {
        let numbers: Vec<i32> = text
            .split_whitespace()
            .map(str::parse)
            .collect::<Result<_, _>>()
            .ok()?;
        let offsets = match numbers.as_slice() {
            [both] => Offsets {
                core: *both,
                cache: *both,
            },
            [core, cache] => Offsets {
                core: *core,
                cache: *cache,
            },
            _ => return None,
        };
        let valid = |mv: i32| (DEEPEST..=0).contains(&mv);
        (valid(offsets.core) && valid(offsets.cache) && offsets.planes() != [0, 0])
            .then_some(offsets)
    }

    fn planes(self) -> [i32; 2] {
        [self.core, self.cache]
    }

    /// As `parse` reads it.
    fn record(self) -> String {
        if self.core == self.cache {
            self.core.to_string()
        } else {
            format!("{} {}", self.core, self.cache)
        }
    }

    /// What the CPU has once the mailbox rounds them to its steps.
    fn on_the_cpu(self) -> String {
        let [core, cache] = self.planes().map(|mv| mailbox::decode(mailbox::encode(mv)));
        if self.core == self.cache {
            format!("{core:.1} mV on the CPU core and cache")
        } else {
            format!("{core:.1} mV on the CPU core, {cache:.1} mV on its cache")
        }
    }
}

/// "-70 mV", or "-80 mV on the core and -70 mV on the cache".
impl fmt::Display for Offsets {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        if self.core == self.cache {
            write!(f, "{} mV", self.core)
        } else {
            write!(
                f,
                "{} mV on the core and {} mV on the cache",
                self.core, self.cache
            )
        }
    }
}

enum Setting {
    Off,
    Offset(Offsets),
    Bad(String),
}

fn setting(paths: &Paths) -> Setting {
    match fs::read_to_string(paths.file("offset")) {
        Err(e) if e.kind() == io::ErrorKind::NotFound => Setting::Off,
        Err(e) => Setting::Bad(e.to_string()),
        Ok(text) => match Offsets::parse(&text) {
            Some(offsets) => Setting::Offset(offsets),
            None => Setting::Bad(text.trim().to_string()),
        },
    }
}

fn read_trimmed(path: &Path) -> Option<String> {
    let text = fs::read_to_string(path).ok()?;
    Some(text.trim().to_string()).filter(|t| !t.is_empty())
}

fn held(paths: &Paths) -> Option<String> {
    read_trimmed(&paths.file("held"))
}

/// The boot and offset the CPU was last given an offset in, until it is
/// taken off.
fn armed(paths: &Paths) -> Option<(String, Offsets)> {
    let text = read_trimmed(&paths.file("armed"))?;
    let (boot, offsets) = text.split_once(' ')?;
    Some((boot.to_string(), Offsets::parse(offsets)?))
}

fn boot_id(paths: &Paths) -> io::Result<String> {
    Ok(fs::read_to_string(&paths.boot_id)?.trim().to_string())
}

fn intel(paths: &Paths) -> bool {
    fs::read_to_string(&paths.cpuinfo)
        .map(|t| {
            t.lines()
                .any(|l| l.starts_with("vendor_id") && l.ends_with("GenuineIntel"))
        })
        .unwrap_or(false)
}

fn sync_dir(path: &Path) -> io::Result<()> {
    File::open(path.parent().unwrap_or(Path::new("/")))?.sync_all()
}

/// Written so that a crash a moment later still finds it: `armed` has to be
/// on the disk before the offset is on the CPU.
fn write_durably(path: &Path, text: &str) -> io::Result<()> {
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir)?;
    }
    let tmp = path.with_extension("tmp");
    {
        let mut file = File::create(&tmp)?;
        file.write_all(text.as_bytes())?;
        file.sync_all()?;
    }
    fs::rename(&tmp, path)?;
    sync_dir(path)
}

fn remove_durably(path: &Path) -> io::Result<()> {
    match fs::remove_file(path) {
        Ok(()) => sync_dir(path),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e),
    }
}

/// Keeps the offset off the CPU until somebody applies it again. Only once
/// it is off, or was never on: this forgets that it was armed.
fn hold(paths: &Paths, reason: &str) -> io::Result<String> {
    write_durably(&paths.file("held"), &format!("{reason}\n"))?;
    remove_durably(&paths.file("armed"))?;
    Ok(format!("held: {reason}"))
}

fn take_off(paths: &Paths, msr: &mut dyn Msr) -> io::Result<()> {
    mailbox::set(msr, [0, 0])
        .map_err(|e| io::Error::other(format!("could not take the offset off: {e}")))?;
    remove_durably(&paths.file("armed"))
}

/// Holds the offset and takes it off. While the CPU will not take it off, it
/// stays armed and this fails, so the service's stop (reset) tries again
/// rather than finding nothing to undo.
fn hold_off(paths: &Paths, msr: io::Result<Box<dyn Msr>>, reason: &str) -> io::Result<String> {
    write_durably(&paths.file("held"), &format!("{reason}\n"))?;
    msr.and_then(|mut msr| take_off(paths, msr.as_mut()))
        .map_err(|e| io::Error::other(format!("{reason}; {e}")))?;
    Ok(format!("held: {reason}"))
}

/// Opens the CPU's registers and checks the firmware lets an offset through;
/// the reason it is held otherwise.
fn open_unlocked(paths: &Paths, open: Open) -> Result<Box<dyn Msr>, String> {
    if !intel(paths) {
        return Err(
            "this is not an Intel CPU, which take an offset through their \
                    overclocking mailbox"
                .into(),
        );
    }
    let mut msr = open().map_err(|e| {
        format!("the CPU's registers cannot be written ({e}); is kernel lockdown on?")
    })?;
    match mailbox::locked(msr.as_mut()) {
        Ok(false) => Ok(msr),
        Ok(true) => Err(LOCKED.into()),
        Err(e) => Err(format!("the CPU's lock register cannot be read ({e})")),
    }
}

fn apply(paths: &Paths, open: Open) -> io::Result<String> {
    let offsets = match setting(paths) {
        Setting::Off => return Ok("no undervolt is set".into()),
        Setting::Bad(text) => {
            return hold(
                paths,
                &format!(
                    "the offset '{text}' is not a whole number of millivolts from {DEEPEST} to -1, \
                     or one for the core and one for the cache from {DEEPEST} to 0"
                ),
            )
        }
        Setting::Offset(offsets) => offsets,
    };
    if let Some(reason) = held(paths) {
        return Ok(format!("held: {reason}"));
    }
    let boot = boot_id(paths)?;
    if let Some((was, at)) = armed(paths) {
        if was != boot {
            return hold(
                paths,
                &format!(
                    "the computer stopped without shutting down while undervolted by {at} \
                     (a freeze, a forced power-off or a flat battery)"
                ),
            );
        }
    }
    let mut msr = match open_unlocked(paths, open) {
        Ok(msr) => msr,
        Err(reason) => return hold(paths, &reason),
    };
    write_durably(
        &paths.file("armed"),
        &format!("{boot} {}\n", offsets.record()),
    )?;
    if let Err(e) = mailbox::set(msr.as_mut(), offsets.planes()) {
        return hold_off(
            paths,
            Ok(msr),
            &format!("the CPU did not take {offsets}: {e}"),
        );
    }
    Ok(offsets.on_the_cpu())
}

fn reset(paths: &Paths, open: Open) -> io::Result<String> {
    if armed(paths).is_none() {
        return Ok("not undervolted".into());
    }
    take_off(paths, open()?.as_mut())?;
    Ok("the offset is off".into())
}

/// After a sleep: the offset again, as a hibernate's power cycle (and some
/// firmware on a resume from suspend) puts the CPU back to none.
fn reapply(paths: &Paths, open: Open) -> io::Result<String> {
    let boot = boot_id(paths)?;
    let offsets = match armed(paths) {
        Some((was, offsets)) if was == boot => offsets,
        _ => return Ok("not undervolted".into()),
    };
    let mut msr = match open_unlocked(paths, open) {
        Ok(msr) => msr,
        Err(reason) => return hold(paths, &reason),
    };
    if let Err(e) = mailbox::set(msr.as_mut(), offsets.planes()) {
        return hold_off(
            paths,
            Ok(msr),
            &format!("the CPU did not take {offsets} after sleep: {e}"),
        );
    }
    Ok(format!("{offsets} again after sleep"))
}

/// A /dev/kmsg record's message: what follows "level,seq,time,flags;", up to
/// the first newline (continuation lines follow it).
fn message(record: &str) -> &str {
    let text = record.split_once(';').map_or(record, |(_, m)| m);
    text.lines().next().unwrap_or("")
}

fn machine_check(record: &str) -> Option<&str> {
    let line = message(record);
    line.contains("[Hardware Error]").then_some(line)
}

/// Waits for a machine check while the offset is on. The first one takes it
/// off: at -80 mV, a P1 Gen 4i logged them and kept running.
fn watch(
    paths: &Paths,
    open: Open,
    records: &mut dyn Iterator<Item = String>,
) -> io::Result<String> {
    let boot = boot_id(paths)?;
    let offsets = match armed(paths) {
        Some((was, offsets)) if was == boot => offsets,
        _ => return Ok("not undervolted, so nothing to watch".into()),
    };
    for record in records {
        if let Some(line) = machine_check(&record) {
            let reason =
                format!("the kernel logged a machine check while undervolted by {offsets}: {line}");
            let msr = open().map_err(|e| {
                io::Error::other(format!("the CPU's registers cannot be opened: {e}"))
            });
            hold_off(paths, msr, &reason)?;
            return Err(io::Error::other(reason));
        }
    }
    Err(io::Error::other("the kernel's log ended"))
}

/// The service: listens to the kernel's log before the offset goes on, so a
/// machine check the offset itself causes is caught too, then applies it and
/// watches.
fn run(paths: &Paths, open: Open, records: &mut dyn Iterator<Item = String>) -> io::Result<String> {
    println!("{}", apply(paths, open)?);
    watch(paths, open, records)
}

/// The kernel's log from now on, one record a read.
struct Kmsg(File);

impl Kmsg {
    fn open() -> io::Result<Kmsg> {
        let mut file = File::open("/dev/kmsg")?;
        file.seek(SeekFrom::End(0))?;
        Ok(Kmsg(file))
    }
}

impl Iterator for Kmsg {
    type Item = String;

    fn next(&mut self) -> Option<String> {
        let mut buf = vec![0; 16384];
        loop {
            match self.0.read(&mut buf) {
                Ok(0) => return None,
                Ok(n) => return Some(String::from_utf8_lossy(&buf[..n]).into_owned()),
                // EPIPE: records were overwritten before they were read.
                Err(e) if e.raw_os_error() == Some(32) => continue,
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                Err(_) => return None,
            }
        }
    }
}

fn json_string(text: &str) -> String {
    let mut out = String::from("\"");
    for c in text.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

fn status(paths: &Paths, open: Open, json: bool) -> io::Result<String> {
    let boot = boot_id(paths).unwrap_or_default();
    let (offsets, state, reason) = match setting(paths) {
        Setting::Off => (None, "off", None),
        Setting::Bad(text) => (
            None,
            "held",
            Some(format!("the offset '{text}' is not valid")),
        ),
        Setting::Offset(offsets) => match (held(paths), armed(paths)) {
            (Some(reason), _) => (Some(offsets), "held", Some(reason)),
            (None, Some((was, _))) if was == boot => (Some(offsets), "applied", None),
            _ => (Some(offsets), "pending", None),
        },
    };
    // `intel`: a CPU that takes an offset this way at all, which Settings
    // offers the undervolt on.
    if json {
        let mv = |pick: fn(Offsets) -> i32| offsets.map_or("null".into(), |o| pick(o).to_string());
        return Ok(format!(
            "{{\"core\":{},\"cache\":{},\"state\":\"{state}\",\"reason\":{},\"intel\":{}}}",
            mv(|o| o.core),
            mv(|o| o.cache),
            reason.as_deref().map_or("null".into(), json_string),
            intel(paths),
        ));
    }
    let mut text = match (state, offsets) {
        ("held", _) => format!(
            "The undervolt{} is held: {}.\n\
             nova power undervolt on applies it again; nova power undervolt set <mV> sets a smaller one.",
            offsets.map_or(String::new(), |o| format!(" of {o}")),
            reason.unwrap_or_default()
        ),
        ("applied", Some(o)) => format!("Undervolted: {}.", o.on_the_cpu()),
        ("pending", Some(o)) => format!(
            "An undervolt of {o} is set but not on the CPU in this boot; \
             systemctl status nova-undervolt says why."
        ),
        _ => "No undervolt is set; nova power undervolt set <mV> sets one.".to_string(),
    };
    // The CPU's own answer, where this may read its registers (root).
    if let Ok(mut msr) = open() {
        let lock = match mailbox::locked(msr.as_mut()) {
            Ok(true) => "on",
            Ok(false) => "off",
            Err(_) => "unreadable",
        };
        let planes: Vec<String> = PLANES
            .iter()
            .map(
                |&(plane, name)| match mailbox::offset(msr.as_mut(), plane) {
                    Ok(mv) => format!("{name} {mv:.1} mV"),
                    Err(e) => format!("{name} unreadable ({e})"),
                },
            )
            .collect();
        text.push_str(&format!(
            "\nThe CPU now: {}; Overclocking Lock {lock}.",
            planes.join(", ")
        ));
    }
    Ok(text)
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    let paths = Paths::system();
    let mut open = || CpuMsr::open().map(|msr| Box::new(msr) as Box<dyn Msr>);
    let result = match args.as_slice() {
        ["run"] => Kmsg::open().and_then(|mut kmsg| run(&paths, &mut open, &mut kmsg)),
        ["reset"] => reset(&paths, &mut open),
        ["reapply"] => reapply(&paths, &mut open),
        ["status"] => status(&paths, &mut open, false),
        ["status", "--json"] => status(&paths, &mut open, true),
        _ => {
            eprintln!("Usage: nova-undervolt run | reset | reapply | status [--json]");
            return ExitCode::from(2);
        }
    };
    match result {
        Ok(text) => {
            println!("{text}");
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("nova-undervolt: {e}");
            ExitCode::FAILURE
        }
    }
}

#[cfg(test)]
mod tests {
    use super::mailbox::fake::Fake;
    use super::*;
    use std::cell::RefCell;
    use std::rc::Rc;
    use std::sync::atomic::{AtomicUsize, Ordering};

    /// One fake CPU that the code under test opens as often as it likes.
    #[derive(Clone)]
    struct Cpu(Rc<RefCell<Fake>>);

    impl Msr for Cpu {
        fn read(&mut self, register: u32) -> io::Result<u64> {
            self.0.borrow_mut().read(register)
        }
        fn write(&mut self, register: u32, value: u64) -> io::Result<()> {
            self.0.borrow_mut().write(register, value)
        }
    }

    struct Machine {
        paths: Paths,
        cpu: Cpu,
    }

    impl Machine {
        fn new() -> Machine {
            static N: AtomicUsize = AtomicUsize::new(0);
            let root = std::env::temp_dir().join(format!(
                "nova-undervolt-test-{}-{}",
                std::process::id(),
                N.fetch_add(1, Ordering::SeqCst)
            ));
            let _ = fs::remove_dir_all(&root);
            fs::create_dir_all(&root).unwrap();
            fs::write(root.join("boot_id"), "boot-1\n").unwrap();
            fs::write(root.join("cpuinfo"), "vendor_id\t: GenuineIntel\n").unwrap();
            Machine {
                paths: Paths {
                    state: root.join("state"),
                    boot_id: root.join("boot_id"),
                    cpuinfo: root.join("cpuinfo"),
                },
                cpu: Cpu(Rc::new(RefCell::new(Fake::new()))),
            }
        }

        fn set_offset(&self, text: &str) {
            fs::create_dir_all(&self.paths.state).unwrap();
            fs::write(self.paths.file("offset"), text).unwrap();
        }

        fn reboot(&self) {
            fs::write(&self.paths.boot_id, "boot-2\n").unwrap();
            self.cpu.0.borrow_mut().planes = [0x0000_0123; 5];
        }

        fn run(&self, f: fn(&Paths, Open) -> io::Result<String>) -> String {
            let cpu = self.cpu.clone();
            let mut open = move || Ok(Box::new(cpu.clone()) as Box<dyn Msr>);
            f(&self.paths, &mut open).unwrap()
        }

        fn json(&self) -> String {
            let mut open = || Err(io::Error::from_raw_os_error(13));
            status(&self.paths, &mut open, true).unwrap()
        }

        fn core(&self) -> f64 {
            mailbox::offset(&mut self.cpu.clone(), 0).unwrap()
        }

        fn writes(&self) -> usize {
            self.cpu.0.borrow().writes
        }
    }

    impl Drop for Machine {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(self.paths.boot_id.parent().unwrap());
        }
    }

    #[test]
    fn nothing_set_touches_nothing() {
        let m = Machine::new();
        assert_eq!(m.run(apply), "no undervolt is set");
        assert_eq!(m.writes(), 0);
        assert_eq!(
            m.json(),
            r#"{"core":null,"cache":null,"state":"off","reason":null,"intel":true}"#
        );
    }

    #[test]
    fn applied_it_is_armed_for_this_boot_and_reset_takes_it_off() {
        let m = Machine::new();
        m.set_offset("-70\n");
        assert_eq!(m.run(apply), "-70.3 mV on the CPU core and cache");
        assert!((m.core() - -70.3125).abs() < 1e-9);
        assert_eq!(
            fs::read_to_string(m.paths.file("armed")).unwrap(),
            "boot-1 -70\n"
        );
        assert_eq!(
            m.json(),
            r#"{"core":-70,"cache":-70,"state":"applied","reason":null,"intel":true}"#
        );
        assert_eq!(m.run(reset), "the offset is off");
        assert_eq!(m.core(), 0.0);
        assert!(!m.paths.file("armed").exists());
        // A clean shutdown, then the next boot applies it again.
        m.reboot();
        m.run(apply);
        assert!((m.core() - -70.3125).abs() < 1e-9);
    }

    #[test]
    fn the_core_and_the_cache_each_take_their_own() {
        let m = Machine::new();
        m.set_offset("-80 -70\n");
        assert_eq!(
            m.run(apply),
            "-80.1 mV on the CPU core, -70.3 mV on its cache"
        );
        assert!((m.core() - -80.078125).abs() < 1e-9);
        assert!((mailbox::offset(&mut m.cpu.clone(), 2).unwrap() - -70.3125).abs() < 1e-9);
        assert_eq!(
            fs::read_to_string(m.paths.file("armed")).unwrap(),
            "boot-1 -80 -70\n"
        );
        assert_eq!(
            m.json(),
            r#"{"core":-80,"cache":-70,"state":"applied","reason":null,"intel":true}"#
        );
        // A freeze says what both were.
        m.reboot();
        assert!(m
            .run(apply)
            .contains("undervolted by -80 mV on the core and -70 mV on the cache"));
    }

    #[test]
    fn offsets_are_one_number_for_both_or_one_each() {
        let both = Offsets::parse("-70\n").unwrap();
        assert_eq!(both.planes(), [-70, -70]);
        assert_eq!(both.record(), "-70");
        assert_eq!(both.to_string(), "-70 mV");
        let each = Offsets::parse("-80 -70").unwrap();
        assert_eq!(each.record(), "-80 -70");
        assert_eq!(Offsets::parse("-80 -80").unwrap().record(), "-80");
        // One plane may be left alone, but not both.
        assert_eq!(Offsets::parse("-50 0").unwrap().planes(), [-50, 0]);
        for bad in [
            "0",
            "0 0",
            "-151 -70",
            "-80 5",
            "-80 -70 -60",
            "-80,-70",
            "core -80",
        ] {
            assert_eq!(Offsets::parse(bad), None, "{bad}");
        }
    }

    #[test]
    fn a_boot_after_one_that_never_shut_down_holds_it() {
        let m = Machine::new();
        m.set_offset("-70");
        m.run(apply);
        // A freeze: no reset, and the CPU comes back with no offset.
        m.reboot();
        let writes = m.writes();
        assert!(m
            .run(apply)
            .starts_with("held: the computer stopped without shutting down"));
        assert_eq!(m.writes(), writes);
        assert_eq!(m.core(), 0.0);
        assert!(m.json().contains(r#""state":"held""#));
        // Held, it stays off at every boot until somebody says otherwise.
        m.reboot();
        assert!(m.run(apply).starts_with("held:"));
        assert_eq!(m.writes(), writes);
        assert_eq!(m.run(reset), "not undervolted");
    }

    #[test]
    fn a_locked_or_discarding_cpu_holds_it_with_the_reason() {
        let m = Machine::new();
        m.set_offset("-70");
        m.cpu.0.borrow_mut().lock = true;
        assert!(m.run(apply).contains("Overclocking Lock is on"));
        assert_eq!(m.writes(), 0);
        assert!(!m.paths.file("armed").exists());

        let m = Machine::new();
        m.set_offset("-70");
        m.cpu.0.borrow_mut().discard = true;
        assert!(m.run(apply).contains("the CPU did not take -70 mV"));
        assert!(!m.paths.file("armed").exists());
    }

    #[test]
    fn only_an_intel_cpu_is_tried() {
        let m = Machine::new();
        m.set_offset("-70");
        fs::write(&m.paths.cpuinfo, "vendor_id\t: AuthenticAMD\n").unwrap();
        assert!(m.run(apply).contains("not an Intel CPU"));
        assert_eq!(m.writes(), 0);
    }

    #[test]
    fn an_offset_out_of_range_is_held_not_applied() {
        for bad in ["-200", "20", "0", "-70mV", ""] {
            let m = Machine::new();
            m.set_offset(bad);
            assert!(m.run(apply).starts_with("held: the offset"), "{bad}");
            assert_eq!(m.writes(), 0, "{bad}");
        }
    }

    #[test]
    fn a_machine_check_takes_it_off_and_holds_it() {
        let m = Machine::new();
        m.set_offset("-80");
        m.run(apply);
        let cpu = m.cpu.clone();
        let mut open = move || Ok(Box::new(cpu.clone()) as Box<dyn Msr>);
        let mut records = [
            "6,1,1,-;usb 3-1: new device\n SUBSYSTEM=usb",
            "2,2,2,-;mce: [Hardware Error]: Machine check events logged\n",
            "6,3,3,-;never read",
        ]
        .into_iter()
        .map(String::from);
        let err = watch(&m.paths, &mut open, &mut records).unwrap_err();
        assert!(err.to_string().contains("Machine check events logged"));
        assert_eq!(m.core(), 0.0);
        assert!(m
            .json()
            .contains("machine check while undervolted by -80 mV"));
        assert!(!m.paths.file("armed").exists());
    }

    #[test]
    fn an_offset_the_cpu_will_not_drop_stays_armed_until_reset_takes_it_off() {
        let m = Machine::new();
        m.set_offset("-80");
        m.run(apply);
        m.cpu.0.borrow_mut().discard = true;
        let cpu = m.cpu.clone();
        let mut open = move || Ok(Box::new(cpu.clone()) as Box<dyn Msr>);
        let mut records = ["2,1,1,-;mce: [Hardware Error]: Machine check events logged"]
            .into_iter()
            .map(String::from);
        let err = watch(&m.paths, &mut open, &mut records).unwrap_err();
        assert!(
            err.to_string().contains("could not take the offset off"),
            "{err}"
        );
        // Held, so no boot applies it again, but still armed for reset.
        assert!(m.json().contains(r#""state":"held""#));
        assert!(m.paths.file("armed").exists());
        let cpu = m.cpu.clone();
        let mut open = move || Ok(Box::new(cpu.clone()) as Box<dyn Msr>);
        assert!(reset(&m.paths, &mut open).is_err());
        assert!(m.paths.file("armed").exists());
        m.cpu.0.borrow_mut().discard = false;
        assert_eq!(m.run(reset), "the offset is off");
        assert_eq!(m.core(), 0.0);
        assert!(!m.paths.file("armed").exists());
    }

    #[test]
    fn a_machine_check_as_the_offset_goes_on_is_caught() {
        let m = Machine::new();
        m.set_offset("-80");
        let cpu = m.cpu.clone();
        let mut open = move || Ok(Box::new(cpu.clone()) as Box<dyn Msr>);
        // run reads the log from before the offset is applied.
        let mut records = ["2,1,1,-;mce: [Hardware Error]: Machine check events logged"]
            .into_iter()
            .map(String::from);
        let err = run(&m.paths, &mut open, &mut records).unwrap_err();
        assert!(err
            .to_string()
            .contains("machine check while undervolted by -80 mV"));
        assert_eq!(m.core(), 0.0);
        assert!(m.json().contains(r#""state":"held""#));
    }

    #[test]
    fn nothing_is_watched_while_it_is_not_on() {
        let m = Machine::new();
        let mut open = || Err(io::Error::from_raw_os_error(13));
        let mut records = std::iter::empty();
        assert!(watch(&m.paths, &mut open, &mut records)
            .unwrap()
            .starts_with("not undervolted"));
    }

    #[test]
    fn after_sleep_it_is_put_back() {
        let m = Machine::new();
        m.set_offset("-70");
        assert_eq!(m.run(reapply), "not undervolted");
        m.run(apply);
        m.cpu.0.borrow_mut().planes = [0x0000_0123; 5];
        assert_eq!(m.run(reapply), "-70 mV again after sleep");
        assert!((m.core() - -70.3125).abs() < 1e-9);
    }

    #[test]
    fn records_and_reasons_are_read_and_written_safely() {
        assert_eq!(
            machine_check("2,9,9,-;mce: [Hardware Error]: CPU 0: Machine Check: 0 Bank 12\n x"),
            Some("mce: [Hardware Error]: CPU 0: Machine Check: 0 Bank 12")
        );
        assert_eq!(machine_check("6,1,1,-;Hardware Error-free day"), None);
        assert_eq!(json_string("a \"b\" \\ \n"), r#""a \"b\" \\ \u000a""#);
    }
}
