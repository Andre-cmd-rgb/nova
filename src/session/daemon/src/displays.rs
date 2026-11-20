//! Watches Hyprland's displays come and go, and keeps the laptop's panel
//! and the X11 scale right as they do.
//!
//! A display coming or going runs a clamshell pass (nova-hyprland-monitor-
//! clamshell turns the laptop's panel off with the lid shut on a dock, and
//! brings it back), and X11 apps are told the scale of the displays the pass
//! left on (nova-hyprland-x11-scale). A display with no mode has Hyprland
//! reload until it has one. Docked, the lid moving as logind says is a pass
//! too.

use std::cell::RefCell;
use std::path::Path;
use std::rc::Rc;
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use nova_sd::poll::{poll, sooner, PollFd, POLLIN};
use nova_sd::{Bus, Slot, Value};

use crate::common::{Context, FileLock};
use crate::hypr::{self, Events};
use crate::say;

pub const DUTY: &str = "display-watch";

/// How long things wait, as the old watcher had them, and where logind is;
/// tests make the waits short and logind theirs.
#[derive(Clone)]
pub struct Setup {
    /// An event this soon after another is part of its burst.
    pub burst: Duration,
    /// The pauses before each of the passes that follow a burst.
    pub follow_ups: [Duration; 3],
    /// The pause after the first reload for a display with no mode; it
    /// doubles while under `double_below`, then is `longest`.
    pub first_reload: Duration,
    pub double_below: Duration,
    pub longest: Duration,
    /// Hyprland not answering this many times in a row has gone.
    pub silent_limit: u32,
    /// Docked, a pass after this long without a word from logind.
    pub lid_quiet: Duration,
    /// A system bus that went is listened to again after this.
    pub lid_retry: Duration,
    /// How the reload loop waits.
    pub sleep: Arc<dyn Fn(Duration) + Send + Sync>,
    /// The bus logind is on.
    pub system_bus: Arc<dyn Fn() -> nova_sd::Result<Bus> + Send + Sync>,
}

impl Default for Setup {
    fn default() -> Setup {
        let s = Duration::from_secs;
        Setup {
            burst: Duration::from_millis(500),
            follow_ups: [s(1), s(3), s(7)],
            first_reload: s(3),
            double_below: s(30),
            longest: s(60),
            silent_limit: 20,
            lid_quiet: s(300),
            lid_retry: s(5),
            sleep: Arc::new(thread::sleep),
            system_bus: Arc::new(Bus::system),
        }
    }
}

/// What the pass worker is given.
enum Job {
    Pass,
    Scale,
}

/// Runs passes and scale changes one at a time, on a thread of its own, so
/// that the events keep being read meanwhile. A pass asked for while one is
/// waiting or running is that one: one clamshell pass at a time.
struct Worker {
    jobs: Sender<Job>,
    queued: Arc<Mutex<(bool, bool)>>,
}

impl Worker {
    fn start(ctx: Context) -> Worker {
        let (jobs, inbox): (Sender<Job>, Receiver<Job>) = mpsc::channel();
        let queued = Arc::new(Mutex::new((false, false)));
        let flags = queued.clone();
        let started = thread::Builder::new()
            .name("display-passes".into())
            .spawn(move || {
                for job in inbox {
                    match job {
                        Job::Pass => {
                            if let Ok(mut q) = flags.lock() {
                                q.0 = false;
                            }
                            clamshell_pass(&ctx);
                        }
                        Job::Scale => {
                            if let Ok(mut q) = flags.lock() {
                                q.1 = false;
                            }
                            ctx.run(&["nova-hyprland-x11-scale"]);
                        }
                    }
                }
            });
        if let Err(e) = started {
            say!(DUTY, "could not start the passes' thread: {e}");
        }
        Worker { jobs, queued }
    }

    fn pass(&self) {
        self.ask(Job::Pass);
    }

    fn scale(&self) {
        self.ask(Job::Scale);
    }

    fn ask(&self, job: Job) {
        let Ok(mut queued) = self.queued.lock() else {
            return;
        };
        let flag = match job {
            Job::Pass => &mut queued.0,
            Job::Scale => &mut queued.1,
        };
        if *flag {
            return;
        }
        *flag = true;
        let _ = self.jobs.send(job);
    }
}

/// One clamshell pass, unless another is under way (here or in another
/// watcher: the lock is the file the old one took). A pass that fails leaves
/// the watch running, as nothing would start it again; the passes after it
/// try again. X11 apps then take the scale of the displays the pass left on.
fn clamshell_pass(ctx: &Context) {
    let lock = ctx
        .runtime_dir()
        .ok()
        .and_then(|dir| FileLock::try_take(&dir.join("monitor-clamshell.lock")));
    if lock.is_none() {
        return;
    }
    ctx.run(&["nova-hyprland-monitor-clamshell"]);
    ctx.run(&["nova-hyprland-x11-scale"]);
}

/// The loop that reloads Hyprland while a display has no mode.
///
/// A display powered on after it was found fires no hotplug, and asking the
/// kernel to probe it again takes root: only a reload reads its EDID again,
/// and only the reload shows whether that worked. The machine can sit like
/// this all night, so the reloads back off, from 3 seconds to a minute. One
/// loop runs at a time; one asked for while it runs is run again after it,
/// so that the last event always has a look of its own.
#[derive(Clone)]
struct Modeless {
    state: Arc<Mutex<(bool, bool)>>,
}

impl Modeless {
    fn new() -> Modeless {
        Modeless {
            state: Arc::new(Mutex::new((false, false))),
        }
    }

    fn ask(&self, ctx: &Context, setup: &Setup) {
        {
            let Ok(mut state) = self.state.lock() else {
                return;
            };
            if state.0 {
                state.1 = true;
                return;
            }
            *state = (true, false);
        }
        let (me, ctx, setup) = (self.clone(), ctx.clone(), setup.clone());
        let started = thread::Builder::new()
            .name("display-modes".into())
            .spawn(move || loop {
                reload_while_modeless(&ctx, &setup);
                let Ok(mut state) = me.state.lock() else {
                    return;
                };
                if state.1 {
                    state.1 = false;
                } else {
                    state.0 = false;
                    return;
                }
            });
        if let Err(e) = started {
            say!(DUTY, "could not start the reload loop: {e}");
            if let Ok(mut state) = self.state.lock() {
                state.0 = false;
            }
        }
    }
}

fn reload_while_modeless(ctx: &Context, setup: &Setup) {
    // One loop at a time, as the old watcher held this file: a display duty
    // started again while its old loop still runs leaves that loop the work.
    let Some(_lock) = ctx
        .runtime_dir()
        .ok()
        .and_then(|dir| FileLock::try_take(&dir.join("monitor-modeless.lock")))
    else {
        return;
    };
    let mut pause = setup.first_reload;
    let mut silent = 0;
    loop {
        // Every display has a mode (1): done. Hyprland not saying (2) is no
        // answer, and nothing else will ask again; but one that stays silent
        // has gone, and the session, and the reason for this loop, with it.
        let answer = ctx.run(&["nova-hyprland-monitor-modeless"]).unwrap_or(2);
        match answer {
            1 => return,
            2 => silent += 1,
            _ => silent = 0,
        }
        if silent > setup.silent_limit {
            return;
        }
        // No reload into an update's half-replaced files, which the reload
        // guard holds back: only a reload counts towards the backing off.
        if answer == 0 && ctx.run(&["nova-hyprland-reload-guard", "paused"]) != Some(0) {
            ctx.run(&["hyprctl", "reload"]);
            (setup.sleep)(pause);
            pause = if pause < setup.double_below {
                pause * 2
            } else {
                setup.longest
            };
        } else {
            (setup.sleep)(pause);
        }
    }
}

/// logind on the system bus, listened to while docked: the lid moving (its
/// LidClosed changes) is a pass.
struct Lid {
    bus: Bus,
    _match: Slot,
    words: Rc<RefCell<Vec<bool>>>,
    last_word: Instant,
}

impl Lid {
    fn listen(setup: &Setup) -> Result<Lid, String> {
        let bus = (setup.system_bus)().map_err(|e| e.to_string())?;
        let words = Rc::new(RefCell::new(Vec::new()));
        let heard = words.clone();
        let slot = bus
            .match_signal(
                Some("org.freedesktop.login1"),
                Some("/org/freedesktop/login1"),
                None,
                None,
                move |m| {
                    heard
                        .borrow_mut()
                        .push(lid_moved(&m.args().unwrap_or_default()));
                },
            )
            .map_err(|e| e.to_string())?;
        Ok(Lid {
            bus,
            _match: slot,
            words,
            last_word: Instant::now(),
        })
    }
}

/// Whether a PropertiesChanged's arguments name LidClosed, changed or invalidated.
fn lid_moved(args: &[Value]) -> bool {
    let changed = args.get(1).and_then(Value::as_dict).unwrap_or_default();
    let invalidated = args.get(2).and_then(Value::as_list).unwrap_or_default();
    changed.iter().any(|(k, _)| k.as_str() == Some("LidClosed"))
        || invalidated.iter().any(|v| v.as_str() == Some("LidClosed"))
}

struct Watch<'a> {
    ctx: &'a Context,
    setup: Setup,
    worker: Worker,
    modeless: Modeless,
    last_event: Option<Instant>,
    follow_ups: Vec<Instant>,
    docked: bool,
    lid: Option<Lid>,
    lid_retry: Option<Instant>,
}

impl Watch<'_> {
    /// What a display coming or going sets off, and the start, which may
    /// follow one this did not see.
    fn displays_changed(&mut self) {
        self.after_display_change();
        self.watch_lid_while_docked();
        self.modeless.ask(self.ctx, &self.setup);
    }

    /// Hyprland announces each display twice (v1 and v2), and a dock brings
    /// several at once. The first event of a burst runs a pass; one moments
    /// after another leaves it to the passes 1, 3 and 7 seconds later, which
    /// start over from the newest event. A pass they are in the middle of
    /// finishes.
    fn after_display_change(&mut self) {
        let now = Instant::now();
        if self
            .last_event
            .is_none_or(|last| now.duration_since(last) >= self.setup.burst)
        {
            self.worker.pass();
        }
        self.last_event = Some(now);
        let mut at = now;
        self.follow_ups = self
            .setup
            .follow_ups
            .iter()
            .map(|pause| {
                at += *pause;
                at
            })
            .collect();
    }

    /// The panel goes off only on a laptop with another display on, so only
    /// then is there anything for the lid's watch to catch. Hyprland's lid
    /// switch binds handle the lid itself; the watch catches what they miss,
    /// across a sleep and a wake.
    fn watch_lid_while_docked(&mut self) {
        self.docked = self.ctx.run(&["nova-hw-laptop"]) == Some(0)
            && self.ctx.run(&["nova-hyprland-monitor-external-active"]) == Some(0);
        if !self.docked {
            self.lid = None;
            self.lid_retry = None;
        } else if self.lid.is_none() && self.lid_retry.is_none() {
            self.listen_to_lid();
        }
    }

    fn listen_to_lid(&mut self) {
        match Lid::listen(&self.setup) {
            Ok(lid) => {
                self.lid = Some(lid);
                self.lid_retry = None;
            }
            Err(e) => {
                say!(DUTY, "cannot listen to the lid: {e}");
                self.lid_retry = Some(Instant::now() + self.setup.lid_retry);
            }
        }
    }

    fn next_deadline(&self) -> Option<Instant> {
        let quiet = self
            .lid
            .as_ref()
            .map(|lid| lid.last_word + self.setup.lid_quiet);
        [self.follow_ups.first().copied(), quiet, self.lid_retry]
            .into_iter()
            .flatten()
            .min()
    }

    /// The passes and lid checks whose time has come.
    fn on_time(&mut self, now: Instant) {
        while self.follow_ups.first().is_some_and(|at| *at <= now) {
            self.follow_ups.remove(0);
            self.worker.pass();
        }
        // After five minutes without a word, for drift the lid does not show.
        if let Some(lid) = &mut self.lid {
            if now.duration_since(lid.last_word) >= self.setup.lid_quiet {
                lid.last_word = now;
                self.worker.pass();
            }
        }
        if self.lid_retry.is_some_and(|at| at <= now) {
            self.lid_retry = None;
            if self.docked {
                self.listen_to_lid();
            }
        }
    }

    fn on_lid(&mut self) {
        let Some(lid) = &mut self.lid else { return };
        if let Err(e) = lid.bus.dispatch() {
            // A bus that goes away is listened to again after a pause.
            say!(DUTY, "the system bus went: {e}");
            self.lid = None;
            self.lid_retry = Some(Instant::now() + self.setup.lid_retry);
            return;
        }
        let words: Vec<bool> = lid.words.borrow_mut().drain(..).collect();
        if !words.is_empty() {
            lid.last_word = Instant::now();
        }
        if words.into_iter().any(|moved| moved) {
            self.worker.pass();
        }
    }

    fn on_event(&mut self, line: &str) {
        match hypr::split(line).0 {
            "monitoradded" | "monitoraddedv2" | "monitorremoved" | "monitorremovedv2" => {
                self.displays_changed()
            }
            // A reload may bring other scales (monitors.lua, Settings putting one back).
            "configreloaded" => {
                self.modeless.ask(self.ctx, &self.setup);
                self.worker.scale();
            }
            _ => {}
        }
    }
}

/// Watches the displays of the Hyprland at <hypr> until it ends.
pub fn watch(ctx: &Context, hypr: &Path, setup: Setup) -> Result<(), String> {
    let mut events = Events::connect(hypr).map_err(|e| format!("Hyprland's events: {e}"))?;
    let mut watch = Watch {
        ctx,
        worker: Worker::start(ctx.clone()),
        modeless: Modeless::new(),
        setup,
        last_event: None,
        follow_ups: Vec::new(),
        docked: false,
        lid: None,
        lid_retry: None,
    };
    watch.displays_changed();
    loop {
        let mut fds = vec![PollFd::new(events.fd(), POLLIN)];
        if let Some(lid) = &watch.lid {
            fds.push(lid.bus.poll_fd());
        }
        let deadline = watch
            .next_deadline()
            .map(|at| at.saturating_duration_since(Instant::now()));
        let bus_timeout = watch.lid.as_ref().and_then(|lid| lid.bus.timeout());
        poll(&mut fds, sooner(deadline, bus_timeout))
            .map_err(|e| format!("could not wait: {e}"))?;
        if fds[0].ready() {
            let Some(lines) = events
                .lines()
                .map_err(|e| format!("Hyprland's events: {e}"))?
            else {
                return Err("Hyprland's events ended".into());
            };
            for line in lines {
                watch.on_event(&line);
            }
        }
        if fds.get(1).is_some_and(PollFd::ready) || bus_timeout.is_some_and(|t| t.is_zero()) {
            watch.on_lid();
        }
        watch.on_time(Instant::now());
    }
}

pub fn run(ctx: &Context) -> Result<(), String> {
    let Some(hypr) = ctx.hypr.clone() else {
        say!(DUTY, "not running inside a Hyprland session");
        return Ok(());
    };
    watch(ctx, &hypr, Setup::default())
}

#[cfg(test)]
mod tests {
    use super::*;
    use nova_sd::testing::scratch;
    use std::fs;
    use std::io::Write;
    use std::os::unix::fs::PermissionsExt;
    use std::os::unix::net::UnixListener;
    use std::path::PathBuf;

    /// A folder of stub helpers that log their calls to <dir>/calls, and a context that runs them.
    fn stubs(dir: &Path, bodies: &[(&str, &str)]) -> Context {
        crate::testing::no_real_buses();
        let bin = dir.join("bin");
        fs::create_dir_all(&bin).unwrap();
        let calls = dir.join("calls");
        for name in [
            "nova-hyprland-monitor-clamshell",
            "nova-hyprland-x11-scale",
            "nova-hyprland-monitor-modeless",
            "nova-hyprland-reload-guard",
            "nova-hw-laptop",
            "nova-hyprland-monitor-external-active",
            "hyprctl",
        ] {
            let body = bodies
                .iter()
                .find(|(n, _)| *n == name)
                .map(|(_, b)| *b)
                .unwrap_or("exit 0");
            let file = bin.join(name);
            fs::write(
                &file,
                format!(
                    "#!/bin/bash\necho \"{name} $*\" >>'{}'\n{body}\n",
                    calls.display()
                ),
            )
            .unwrap();
            fs::set_permissions(&file, fs::Permissions::from_mode(0o755)).unwrap();
        }
        Context {
            runtime: dir.join("run"),
            hypr: Some(dir.join("hypr")),
            session: String::new(),
            bin: Some(bin),
            proc: PathBuf::from("/proc"),
        }
    }

    fn calls(dir: &Path) -> Vec<String> {
        fs::read_to_string(dir.join("calls"))
            .unwrap_or_default()
            .lines()
            .map(str::to_owned)
            .collect()
    }

    fn count(dir: &Path, name: &str) -> usize {
        calls(dir)
            .iter()
            .filter(|c| c.split(' ').next() == Some(name))
            .count()
    }

    fn quick(pauses: Arc<Mutex<Vec<Duration>>>) -> Setup {
        let ms = Duration::from_millis;
        Setup {
            burst: ms(150),
            follow_ups: [ms(100), ms(100), ms(100)],
            first_reload: ms(3),
            double_below: ms(30),
            longest: ms(60),
            silent_limit: 20,
            lid_quiet: Duration::from_secs(300),
            lid_retry: Duration::from_secs(5),
            sleep: Arc::new(move |pause| {
                pauses.lock().unwrap().push(pause);
                thread::sleep(Duration::from_millis(1));
            }),
            system_bus: Arc::new(|| {
                Err(nova_sd::Error::bus(
                    "org.nova.Test",
                    "no system bus in tests",
                ))
            }),
        }
    }

    /// Runs the watch against a Hyprland that sends <events>, until <done>
    /// holds (five seconds at most: on a busy machine the stubs are slow to
    /// start, so no test counts on how long they take), and a moment more,
    /// for anything that should not have come to come; then ends.
    fn run_watch(
        dir: &Path,
        ctx: &Context,
        setup: Setup,
        events: &[&str],
        done: impl Fn() -> bool,
    ) {
        let hypr = dir.join("hypr");
        fs::create_dir_all(&hypr).unwrap();
        let listener = UnixListener::bind(hypr.join(".socket2.sock")).unwrap();
        let ctx2 = ctx.clone();
        let hypr2 = hypr.clone();
        let watcher = thread::spawn(move || watch(&ctx2, &hypr2, setup));
        let (mut hyprland, _) = listener.accept().unwrap();
        for event in events {
            hyprland.write_all(format!("{event}\n").as_bytes()).unwrap();
        }
        settled(done);
        drop(hyprland);
        let ended = watcher.join().unwrap();
        assert_eq!(ended.unwrap_err(), "Hyprland's events ended");
    }

    /// Waits until <done> holds, five seconds at most, then 150 ms more.
    fn settled(done: impl Fn() -> bool) {
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        while !done() && std::time::Instant::now() < deadline {
            thread::sleep(Duration::from_millis(10));
        }
        thread::sleep(Duration::from_millis(150));
    }

    #[test]
    fn a_burst_of_display_events_is_one_pass_at_once_then_the_passes_after_it() {
        let dir = scratch("displays");
        let ctx = stubs(
            &dir,
            &[
                ("nova-hw-laptop", "exit 1"),
                ("nova-hyprland-monitor-modeless", "exit 1"),
            ],
        );
        // A burst as long as the test, and the passes after it later still:
        // how quickly the events are taken in does not matter.
        let mut setup = quick(Arc::new(Mutex::new(Vec::new())));
        setup.burst = Duration::from_secs(10);
        setup.follow_ups = [Duration::from_secs(60); 3];
        let hypr = dir.join("hypr");
        fs::create_dir_all(&hypr).unwrap();
        let listener = UnixListener::bind(hypr.join(".socket2.sock")).unwrap();
        let (ctx2, hypr2) = (ctx.clone(), hypr.clone());
        let watcher = thread::spawn(move || watch(&ctx2, &hypr2, setup));
        let (mut hyprland, _) = listener.accept().unwrap();
        // The start counts as the first event of the burst: one pass, X11
        // apps told the scale after it, and a look for displays with no mode.
        crate::testing::wait_until("the start's look", || {
            count(&dir, "nova-hyprland-monitor-modeless") == 1
                && count(&dir, "nova-hyprland-x11-scale") == 1
        });
        for event in [
            "monitoradded>>DP-2",
            "monitoraddedv2>>2,DP-2,Dell",
            "workspace>>3",
        ] {
            hyprland.write_all(format!("{event}\n").as_bytes()).unwrap();
        }
        // A display event in the burst is no pass of its own, but a look for
        // displays with no mode after it (those asked for while one looks
        // are looked at once more after it).
        settled(|| count(&dir, "nova-hyprland-monitor-modeless") >= 2);
        drop(hyprland);
        assert_eq!(
            watcher.join().unwrap().unwrap_err(),
            "Hyprland's events ended"
        );
        assert!(count(&dir, "nova-hyprland-monitor-modeless") >= 2);
        assert_eq!(count(&dir, "nova-hyprland-monitor-clamshell"), 1);
        assert_eq!(count(&dir, "nova-hyprland-x11-scale"), 1);
    }

    #[test]
    fn the_passes_after_a_burst_come_after_their_pauses_and_a_reload_tells_x11_the_scale() {
        let dir = scratch("displays");
        let ctx = stubs(
            &dir,
            &[
                ("nova-hw-laptop", "exit 1"),
                ("nova-hyprland-monitor-modeless", "exit 1"),
            ],
        );
        let pauses = Arc::new(Mutex::new(Vec::new()));
        run_watch(&dir, &ctx, quick(pauses), &["configreloaded>>"], || {
            count(&dir, "nova-hyprland-monitor-clamshell") >= 4
                && count(&dir, "nova-hyprland-x11-scale") >= 5
        });
        // The start's pass and the three after it, each with the scale after
        // it, and the reload's scale.
        assert_eq!(count(&dir, "nova-hyprland-monitor-clamshell"), 4);
        assert_eq!(count(&dir, "nova-hyprland-x11-scale"), 5);
    }

    #[test]
    fn a_display_with_no_mode_has_hyprland_reloaded_less_often_each_time_until_it_has_one() {
        let dir = scratch("displays");
        fs::write(dir.join("modes"), "0\n0\n0\n0\n0\n0\n1\n").unwrap();
        let modeless = format!(
            "answer=$(head -n 1 '{0}/modes' 2>/dev/null); sed -i 1d '{0}/modes' 2>/dev/null; exit \"${{answer:-1}}\"",
            dir.display()
        );
        let ctx = stubs(
            &dir,
            &[
                ("nova-hw-laptop", "exit 1"),
                ("nova-hyprland-monitor-modeless", &modeless),
                ("nova-hyprland-reload-guard", "exit 1"),
            ],
        );
        let pauses = Arc::new(Mutex::new(Vec::new()));
        run_watch(&dir, &ctx, quick(pauses.clone()), &[], || {
            count(&dir, "hyprctl") >= 6 && pauses.lock().unwrap().len() >= 6
        });
        assert_eq!(count(&dir, "hyprctl"), 6);
        let ms: Vec<u128> = pauses
            .lock()
            .unwrap()
            .iter()
            .map(|p| p.as_millis())
            .collect();
        // 3, 6, 12, 24, 48 and then at most a "minute".
        assert_eq!(ms, vec![3, 6, 12, 24, 48, 60]);
    }

    #[test]
    fn no_reload_while_an_update_holds_reloads_back_nor_while_hyprland_does_not_answer() {
        let dir = scratch("displays");
        fs::write(dir.join("modes"), "0\n0\n2\n1\n").unwrap();
        let modeless = format!(
            "answer=$(head -n 1 '{0}/modes' 2>/dev/null); sed -i 1d '{0}/modes' 2>/dev/null; exit \"${{answer:-1}}\"",
            dir.display()
        );
        let ctx = stubs(
            &dir,
            &[
                ("nova-hw-laptop", "exit 1"),
                ("nova-hyprland-monitor-modeless", &modeless),
                ("nova-hyprland-reload-guard", "[[ $1 == paused ]]"),
            ],
        );
        let pauses = Arc::new(Mutex::new(Vec::new()));
        run_watch(&dir, &ctx, quick(pauses.clone()), &[], || {
            pauses.lock().unwrap().len() >= 3
        });
        assert_eq!(count(&dir, "hyprctl"), 0);
        assert_eq!(pauses.lock().unwrap().len(), 3);
        assert!(pauses
            .lock()
            .unwrap()
            .iter()
            .all(|p| *p == Duration::from_millis(3)));
    }

    #[test]
    fn a_hyprland_that_stays_silent_is_given_up_on_after_21_asks() {
        let dir = scratch("displays");
        let ctx = stubs(
            &dir,
            &[
                ("nova-hw-laptop", "exit 1"),
                ("nova-hyprland-monitor-modeless", "exit 2"),
            ],
        );
        let pauses = Arc::new(Mutex::new(Vec::new()));
        run_watch(&dir, &ctx, quick(pauses), &[], || {
            count(&dir, "nova-hyprland-monitor-modeless") >= 21
        });
        assert_eq!(count(&dir, "nova-hyprland-monitor-modeless"), 21);
        assert_eq!(count(&dir, "hyprctl"), 0);
    }

    #[test]
    fn a_change_asked_for_while_the_reload_loop_runs_is_looked_at_after_it() {
        let dir = scratch("displays");
        let ctx = stubs(
            &dir,
            &[("nova-hyprland-monitor-modeless", "sleep 0.5; exit 1")],
        );
        let setup = quick(Arc::new(Mutex::new(Vec::new())));
        let modeless = Modeless::new();
        modeless.ask(&ctx, &setup);
        // The others once the first loop is under way: asked before it
        // starts, they are all its, and one loop is right.
        crate::testing::wait_until("the first loop", || {
            count(&dir, "nova-hyprland-monitor-modeless") >= 1
        });
        modeless.ask(&ctx, &setup);
        modeless.ask(&ctx, &setup);
        settled(|| count(&dir, "nova-hyprland-monitor-modeless") >= 2);
        thread::sleep(Duration::from_millis(300));
        // The first loop, and one more for the asks it was busy through.
        assert_eq!(count(&dir, "nova-hyprland-monitor-modeless"), 2);
    }

    #[test]
    fn docked_the_lid_moving_as_logind_says_is_a_pass_and_the_lids_watch_ends_with_the_watch() {
        let Some(private) = nova_sd::testing::PrivateBus::start() else {
            return;
        };
        let dir = scratch("displays");
        let ctx = stubs(&dir, &[("nova-hyprland-monitor-modeless", "exit 1")]);
        let logind = crate::testing::Service::start(&private.address, |bus| {
            assert!(bus.request_name("org.freedesktop.login1", 0).unwrap());
            Box::new(())
        });
        let mut setup = quick(Arc::new(Mutex::new(Vec::new())));
        // The passes after the start's are not this test's.
        setup.follow_ups = [Duration::from_secs(60); 3];
        let address = private.address.clone();
        setup.system_bus = Arc::new(move || Bus::connect(&address));
        let hypr = dir.join("hypr");
        fs::create_dir_all(&hypr).unwrap();
        let listener = UnixListener::bind(hypr.join(".socket2.sock")).unwrap();
        let (ctx2, hypr2) = (ctx.clone(), hypr.clone());
        let watcher = thread::spawn(move || watch(&ctx2, &hypr2, setup));
        let (hyprland, _) = listener.accept().unwrap();
        let watching = Bus::connect(&private.address).unwrap();
        crate::testing::wait_until("the lid's watch", || {
            let owners = watching
                .call(
                    "org.freedesktop.DBus",
                    "/org/freedesktop/DBus",
                    "org.freedesktop.DBus",
                    "ListNames",
                    &[],
                )
                .unwrap();
            owners[0].as_list().unwrap().len() >= 5
        });
        let changed = |key: &'static str| {
            move |bus: &Bus, _: &mut Box<dyn std::any::Any>| {
                bus.emit_properties_changed(
                    "/org/freedesktop/login1",
                    "org.freedesktop.login1.Manager",
                    vec![(key, Value::Bool(true))],
                )
                .unwrap()
            }
        };
        // The start's pass, then a change that is not the lid, then the lid shut.
        crate::testing::wait_until("the start's pass", || {
            count(&dir, "nova-hyprland-monitor-clamshell") == 1
        });
        logind.send(changed("IdleHint"));
        thread::sleep(Duration::from_millis(100));
        assert_eq!(count(&dir, "nova-hyprland-monitor-clamshell"), 1);
        // Said again until it is heard: the watch is on the bus before its
        // match is, and a word said in between reaches nobody.
        let mut said: Option<std::time::Instant> = None;
        crate::testing::wait_until("the lid's pass", || {
            if count(&dir, "nova-hyprland-monitor-clamshell") >= 2 {
                return true;
            }
            if said.is_none_or(|at| at.elapsed() > Duration::from_millis(500)) {
                logind.send(changed("LidClosed"));
                said = Some(std::time::Instant::now());
            }
            false
        });
        drop(hyprland);
        assert!(watcher.join().unwrap().is_err());
        // Nothing is left listening: the watch's connection went with it.
        crate::testing::wait_until("the lid's watch to go", || {
            let owners = watching
                .call(
                    "org.freedesktop.DBus",
                    "/org/freedesktop/DBus",
                    "org.freedesktop.DBus",
                    "ListNames",
                    &[],
                )
                .unwrap();
            owners[0].as_list().unwrap().len() == 4
        });
    }

    #[test]
    fn the_lid_moving_is_a_pass_and_other_changes_are_not() {
        let props = |key: &str| {
            vec![
                Value::str("org.freedesktop.login1.Manager"),
                Value::options(vec![(key, Value::Bool(true))]),
                Value::Array("s".into(), vec![]),
            ]
        };
        assert!(lid_moved(&props("LidClosed")));
        assert!(!lid_moved(&props("IdleHint")));
        assert!(lid_moved(&[
            Value::str("org.freedesktop.login1.Manager"),
            Value::Dict("s".into(), "v".into(), vec![]),
            Value::strings(&["LidClosed"]),
        ]));
        assert!(!lid_moved(&[Value::Bool(true)]));
    }
}
