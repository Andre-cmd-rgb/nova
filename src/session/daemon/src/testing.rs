//! For the tests: services on a private bus, each on a thread of its own,
//! stub helpers, and waiting for something to happen.

use std::any::Any;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Sender};
use std::sync::Arc;
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use nova_sd::poll::{poll, sooner};
use nova_sd::Bus;

use crate::common::Context;

type Errand = Box<dyn FnOnce(&Bus, &mut Box<dyn Any>) + Send>;

/// A service on its own connection and thread: set up once, then running
/// errands sent to it, until it is dropped.
pub struct Service {
    stop: Arc<AtomicBool>,
    errands: Sender<Errand>,
    thread: Option<JoinHandle<()>>,
}

impl Service {
    /// <setup> makes the service on its connection, and gives back its state,
    /// which the errands get.
    pub fn start<F>(address: &str, setup: F) -> Service
    where
        F: FnOnce(&Bus) -> Box<dyn Any> + Send + 'static,
    {
        let stop = Arc::new(AtomicBool::new(false));
        let (errands, inbox) = mpsc::channel::<Errand>();
        let (ready, started) = mpsc::channel();
        let address = address.to_owned();
        let stopping = stop.clone();
        let thread = thread::spawn(move || {
            let bus = Bus::connect(&address).expect("a connection to the private bus");
            let mut state = setup(&bus);
            ready.send(()).unwrap();
            while !stopping.load(Ordering::Relaxed) {
                while let Ok(errand) = inbox.try_recv() {
                    errand(&bus, &mut state);
                }
                let mut fds = [bus.poll_fd()];
                let _ = poll(
                    &mut fds,
                    sooner(bus.timeout(), Some(Duration::from_millis(10))),
                );
                if bus.dispatch().is_err() {
                    break;
                }
            }
        });
        started
            .recv_timeout(Duration::from_secs(5))
            .expect("the service started");
        Service {
            stop,
            errands,
            thread: Some(thread),
        }
    }

    /// Runs <errand> on the service's thread, with its connection and state.
    pub fn send<F: FnOnce(&Bus, &mut Box<dyn Any>) + Send + 'static>(&self, errand: F) {
        self.errands.send(Box::new(errand)).unwrap();
    }
}

impl Drop for Service {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

/// A duty's serve() on its own connection to the private bus, on a thread.
pub fn duty(
    address: &str,
    ctx: &Context,
    serve: fn(&Bus, &Context) -> Result<(), String>,
) -> JoinHandle<Result<(), String>> {
    let (address, ctx) = (address.to_owned(), ctx.clone());
    thread::spawn(move || {
        let bus = Bus::connect(&address).map_err(|e| e.to_string())?;
        serve(&bus, &ctx)
    })
}

/// Points the session and system buses of this test process at nothing, so
/// that a duty that connects to them by mistake fails instead of reaching the
/// computer's own.
pub fn no_real_buses() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        std::env::set_var(
            "DBUS_SYSTEM_BUS_ADDRESS",
            "unix:path=/nonexistent/nova-tests-use-no-system-bus",
        );
        std::env::set_var(
            "DBUS_SESSION_BUS_ADDRESS",
            "unix:path=/nonexistent/nova-tests-use-no-session-bus",
        );
    });
}

/// A context in <dir>: the runtime folder made, and helpers from <dir>/bin.
pub fn context(dir: &Path) -> Context {
    no_real_buses();
    let ctx = Context {
        runtime: dir.join("run/nova"),
        hypr: None,
        session: "test-session".into(),
        login: String::new(),
        bin: Some(dir.join("bin")),
        proc: PathBuf::from("/proc"),
    };
    fs::create_dir_all(&ctx.runtime).unwrap();
    fs::create_dir_all(dir.join("bin")).unwrap();
    ctx
}

/// A stub helper in <dir>/bin that logs "name args" to <dir>/calls, then runs <body>.
pub fn stub(dir: &Path, name: &str, body: &str) {
    let file = dir.join("bin").join(name);
    fs::write(
        &file,
        format!(
            "#!/bin/bash\necho \"{name}${{*:+ $*}}\" >>'{}'\n{body}\n",
            dir.join("calls").display()
        ),
    )
    .unwrap();
    fs::set_permissions(&file, fs::Permissions::from_mode(0o755)).unwrap();
}

pub fn calls(dir: &Path) -> Vec<String> {
    fs::read_to_string(dir.join("calls"))
        .unwrap_or_default()
        .lines()
        .map(str::to_owned)
        .collect()
}

/// Waits until <done> holds, five seconds at most.
pub fn wait_until(what: &str, mut done: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while !done() {
        assert!(Instant::now() < deadline, "waited five seconds for {what}");
        thread::sleep(Duration::from_millis(10));
    }
}

/// This process's children that ended and were never waited for.
pub fn zombies() -> usize {
    let me = std::process::id().to_string();
    fs::read_dir("/proc")
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|e| fs::read_to_string(e.path().join("status")).ok())
        .filter(|s| s.contains("\nState:\tZ") && s.lines().any(|l| l == format!("PPid:\t{me}")))
        .count()
}
