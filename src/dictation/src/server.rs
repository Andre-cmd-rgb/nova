//! The daemon: one dictation at a time, for the shell, on a socket in the
//! user's private runtime folder ($XDG_RUNTIME_DIR/nova/dictation.sock).
//!
//! One connection is one dictation, a line each way at a time:
//!
//!   shell   start         listen: the microphone opens, the model loads
//!   daemon  {"type":"listening"}
//!   shell   finish        let go: the rest is heard, and its words come
//!   daemon  {"type":"text","text":"…"}            and the connection ends
//!   shell   cancel        (or the connection closed before finish) stop,
//!                         and forget it
//!   daemon  {"type":"error","error":"…"}          no-model, no-engine,
//!                                                 microphone, engine, busy
//!   any     status        {"type":"status","loaded":…,"busy":…,"unload_in":…}
//!
//! The recording is pw-record's (16 kHz mono 16-bit, on a pipe: no file),
//! heard on the engine thread while it is said (dictation.rs says when),
//! and kept in memory only until its words are out. The words, tidied
//! (tidy.rs) and with the user's own spellings (vocab.rs), are also kept in
//! $XDG_RUNTIME_DIR/nova/dictation/last for `nova dictation last`, so that a
//! paste that went to the wrong window is never lost.
//!
//! The model is about 700 MB of memory, held only while it is of use: the
//! process ends two minutes after the last dictation, at once when the
//! computer is about to sleep or memory runs short, and systemd starts it
//! again at the next (nova-dictationd.socket). The load, a tenth of a second
//! or so, happens while the first words are said.

use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, RawFd};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdout, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc};
use std::thread;
use std::time::{Duration, Instant};

use nova_sd::poll::{poll, PollFd, POLLIN, POLLPRI};

use crate::dictation::{Dictation, Next, Window};
use crate::engine::{Ear, Token};
use crate::system::{self, Pressure, System};
use crate::tidy;
use crate::vocab::Vocab;

/// Loads the model, on the engine thread.
pub type Loader = Box<dyn FnMut() -> Result<Box<dyn Ear>, String> + Send>;

/// How long the process stays with nothing loaded (after a status, say).
const IDLE_EMPTY: Duration = Duration::from_secs(2);
/// How long pw-record has to end once asked, before it is killed.
const STOP_GRACE: Duration = Duration::from_secs(1);
/// The longest line the shell sends: its words are short.
const LONGEST_LINE: usize = 256;

pub struct Config {
    /// The speech model: a dictation without it is answered no-model.
    pub model: PathBuf,
    /// Whether the speech engine is installed: no-engine without it.
    pub engine: bool,
    /// What records: pw-record, or a test's player.
    pub recorder: Vec<String>,
    /// Where `last` goes.
    pub runtime: PathBuf,
    /// The user's spellings (vocab.rs).
    pub vocab: PathBuf,
    /// Where the power supplies are (/sys/class/power_supply).
    pub supplies: PathBuf,
    /// How long the model stays loaded after the last dictation.
    pub idle: Duration,
    /// Threads while it is said, and for the end.
    pub look_threads: usize,
    pub last_threads: usize,
    /// The system bus: a sleep coming, the CPU held up on battery (none in tests).
    pub system: Option<System>,
    /// Memory running short (none in tests).
    pub pressure: Option<Pressure>,
}

enum Job {
    Load,
    Hear {
        id: u64,
        samples: Vec<f32>,
        threads: usize,
        stop: Arc<AtomicBool>,
    },
}

enum Done {
    Loaded(Result<(), String>),
    Heard {
        id: u64,
        heard: Result<Vec<Token>, String>,
    },
}

/// The engine thread: the model, loaded on the first job and kept.
struct Worker {
    jobs: mpsc::Sender<Job>,
    done: mpsc::Receiver<Done>,
    /// A byte for each answer, for poll().
    wake: UnixStream,
}

fn ensure(ear: &mut Option<Box<dyn Ear>>, load: &mut Loader) -> Result<(), String> {
    if ear.is_none() {
        *ear = Some(load()?);
    }
    Ok(())
}

impl Worker {
    fn start(mut load: Loader) -> io::Result<Worker> {
        let (jobs, queue) = mpsc::channel::<Job>();
        let (answers, done) = mpsc::channel::<Done>();
        let (wake, mut ring) = UnixStream::pair()?;
        thread::Builder::new()
            .name("engine".into())
            .spawn(move || {
                let mut ear: Option<Box<dyn Ear>> = None;
                for job in queue {
                    let answer = match job {
                        Job::Load => Done::Loaded(ensure(&mut ear, &mut load)),
                        Job::Hear {
                            id,
                            samples,
                            threads,
                            stop,
                        } => {
                            let heard = if stop.load(Ordering::Relaxed) {
                                Err("stopped".into())
                            } else {
                                ensure(&mut ear, &mut load).and_then(|()| match ear.as_mut() {
                                    Some(ear) => ear.hear(&samples, threads, &stop),
                                    None => Err("no engine".into()),
                                })
                            };
                            Done::Heard { id, heard }
                        }
                    };
                    if answers.send(answer).is_err() || ring.write_all(&[1]).is_err() {
                        break;
                    }
                }
            })?;
        Ok(Worker { jobs, done, wake })
    }
}

extern "C" {
    fn prctl(option: i32, arg: u64, ...) -> i32;
    fn kill(pid: i32, signal: i32) -> i32;
}
const PR_SET_PDEATHSIG: i32 = 1;
const SIGTERM: i32 = 15;

/// pw-record, its samples on a pipe.
struct Recorder {
    child: Child,
    out: ChildStdout,
    /// A byte of a sample whose other byte has not come yet.
    odd: Option<u8>,
    stopped_at: Option<Instant>,
}

impl Recorder {
    fn spawn(command: &[String]) -> io::Result<Recorder> {
        let (program, args) = command
            .split_first()
            .ok_or_else(|| io::Error::other("nothing to record with"))?;
        let mut command = Command::new(program);
        command
            .args(args)
            .stdin(Stdio::null())
            .stdout(Stdio::piped());
        // SAFETY: prctl is async-signal-safe: should the daemon die, the
        // microphone closes with it.
        unsafe {
            command.pre_exec(|| {
                prctl(PR_SET_PDEATHSIG, SIGTERM as u64);
                Ok(())
            });
        }
        let mut child = command.spawn()?;
        let out = child
            .stdout
            .take()
            .ok_or_else(|| io::Error::other("no pipe"))?;
        Ok(Recorder {
            child,
            out,
            odd: None,
            stopped_at: None,
        })
    }

    /// What poll() said is there: samples, or none once it has ended.
    fn read(&mut self) -> Option<Vec<i16>> {
        let mut buf = [0u8; 16384];
        let n = match self.out.read(&mut buf) {
            Ok(0) | Err(_) => return None,
            Ok(n) => n,
        };
        let mut bytes = Vec::with_capacity(n + 1);
        bytes.extend(self.odd.take());
        bytes.extend_from_slice(&buf[..n]);
        if bytes.len() % 2 == 1 {
            self.odd = bytes.pop();
        }
        Some(
            bytes
                .as_chunks::<2>()
                .0
                .iter()
                .map(|&b| i16::from_le_bytes(b))
                .collect(),
        )
    }

    /// Asks it to end, as the shell's SIGTERM did: what it recorded is
    /// written out first.
    fn stop(&mut self) {
        if self.stopped_at.is_none() {
            // SAFETY: a signal to our own child, which is not reaped yet.
            unsafe { kill(self.child.id() as i32, SIGTERM) };
            self.stopped_at = Some(Instant::now());
        }
    }
}

impl Drop for Recorder {
    fn drop(&mut self) {
        if !matches!(self.child.try_wait(), Ok(Some(_))) {
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
    }
}

struct Conn {
    id: u64,
    stream: UnixStream,
    input: Vec<u8>,
    gone: bool,
}

impl Conn {
    /// The lines poll() said are there.
    fn lines(&mut self) -> Vec<String> {
        let mut buf = [0u8; 1024];
        match self.stream.read(&mut buf) {
            Ok(0) | Err(_) => {
                self.gone = true;
                return Vec::new();
            }
            Ok(n) => self.input.extend_from_slice(&buf[..n]),
        }
        let mut lines = Vec::new();
        while let Some(end) = self.input.iter().position(|&b| b == b'\n') {
            let line: Vec<u8> = self.input.drain(..=end).collect();
            lines.push(String::from_utf8_lossy(&line).trim().to_owned());
        }
        if self.input.len() > LONGEST_LINE {
            self.gone = true;
        }
        lines
    }

    fn say(&mut self, line: &str) {
        if self
            .stream
            .write_all(format!("{line}\n").as_bytes())
            .is_err()
        {
            self.gone = true;
        }
    }
}

/// <text> as a JSON string.
pub fn quote(text: &str) -> String {
    let mut out = String::with_capacity(text.len() + 2);
    out.push('"');
    for c in text.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

fn error(reason: &str) -> String {
    format!("{{\"type\":\"error\",\"error\":{}}}", quote(reason))
}

struct Hearing {
    window: Window,
    id: u64,
    stop: Arc<AtomicBool>,
}

struct Session {
    conn: u64,
    dictation: Dictation,
    recorder: Option<Recorder>,
    hearing: Option<Hearing>,
    finishing: bool,
    hold: Option<u32>,
}

pub struct Server {
    config: Config,
    listener: UnixListener,
    worker: Worker,
    conns: Vec<Conn>,
    session: Option<Session>,
    next_id: u64,
    loaded: bool,
    idle_since: Instant,
    /// A sleep is coming, or memory is short: gone once no dictation needs it.
    leaving: bool,
}

/// Keeps <text> as the last dictation's words, for this user alone.
pub fn keep_last(runtime: &Path, text: &str) -> io::Result<()> {
    std::fs::create_dir_all(runtime)?;
    std::fs::set_permissions(runtime, std::fs::Permissions::from_mode(0o700))?;
    let part = runtime.join("last.part");
    let _ = std::fs::remove_file(&part);
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&part)?;
    file.write_all(text.as_bytes())?;
    std::fs::rename(part, runtime.join("last"))
}

impl Server {
    pub fn new(config: Config, listener: UnixListener, load: Loader) -> io::Result<Server> {
        Ok(Server {
            worker: Worker::start(load)?,
            config,
            listener,
            conns: Vec::new(),
            session: None,
            next_id: 0,
            loaded: false,
            idle_since: Instant::now(),
            leaving: false,
        })
    }

    fn id(&mut self) -> u64 {
        self.next_id += 1;
        self.next_id
    }

    /// Serves until there is nothing to stay for.
    pub fn run(mut self) -> Result<(), String> {
        loop {
            let deadline = if self.session.is_some() || !self.conns.is_empty() {
                None
            } else if self.leaving {
                return Ok(());
            } else {
                let limit = if self.loaded {
                    self.config.idle
                } else {
                    IDLE_EMPTY
                };
                let left = limit.saturating_sub(self.idle_since.elapsed());
                if left.is_zero() {
                    if self.loaded {
                        eprintln!(
                            "nova-dictationd: unused for {} s, the model is unloaded",
                            limit.as_secs()
                        );
                    }
                    return Ok(());
                }
                Some(left)
            };
            self.wait(deadline)?;
        }
    }

    fn wait(&mut self, deadline: Option<Duration>) -> Result<(), String> {
        #[derive(Clone, Copy)]
        enum What {
            Listener,
            Engine,
            Bus,
            Pressure,
            Recorder,
            Conn(u64),
        }
        let mut fds = vec![
            PollFd::new(self.listener.as_raw_fd(), POLLIN),
            PollFd::new(self.worker.wake.as_raw_fd(), POLLIN),
        ];
        let mut what = vec![What::Listener, What::Engine];
        let mut timeout = deadline;
        if let Some(system) = &self.config.system {
            fds.push(system.bus.poll_fd());
            what.push(What::Bus);
            timeout = nova_sd::poll::sooner(timeout, system.bus.timeout());
        }
        if let Some(pressure) = &self.config.pressure {
            fds.push(PollFd::new(pressure.fd(), POLLPRI));
            what.push(What::Pressure);
        }
        if let Some(recorder) = self.session.as_ref().and_then(|s| s.recorder.as_ref()) {
            fds.push(PollFd::new(recorder.out.as_raw_fd() as RawFd, POLLIN));
            what.push(What::Recorder);
            if let Some(at) = recorder.stopped_at {
                timeout =
                    nova_sd::poll::sooner(timeout, Some(STOP_GRACE.saturating_sub(at.elapsed())));
            }
        }
        for conn in &self.conns {
            fds.push(PollFd::new(conn.stream.as_raw_fd(), POLLIN));
            what.push(What::Conn(conn.id));
        }
        poll(&mut fds, timeout).map_err(|e| format!("could not wait: {e}"))?;
        for (fd, what) in fds.iter().zip(what) {
            if !fd.ready() {
                continue;
            }
            match what {
                What::Listener => self.accept(),
                What::Engine => self.answers(),
                What::Bus => self.bus()?,
                What::Pressure => {
                    if self.session.is_none() && self.loaded {
                        eprintln!("nova-dictationd: memory is short, the model is unloaded");
                        self.leaving = true;
                    }
                }
                What::Recorder => self.recorded(),
                What::Conn(id) => self.heard_from(id),
            }
        }
        // pw-record that would not end is ended.
        if let Some(s) = &mut self.session {
            if s.recorder
                .as_ref()
                .and_then(|r| r.stopped_at)
                .is_some_and(|at| at.elapsed() >= STOP_GRACE)
            {
                s.recorder = None;
                self.recording_ended();
            }
        }
        // However a connection ended (closed, refused, its answer not
        // written, a status or cancel said), it is decided here, after its
        // lines: the dictation it owned ends with it.
        let gone: Vec<u64> = self.conns.iter().filter(|c| c.gone).map(|c| c.id).collect();
        for id in gone {
            self.left(id);
        }
        self.conns.retain(|c| !c.gone);
        Ok(())
    }

    fn accept(&mut self) {
        if let Ok((stream, _)) = self.listener.accept() {
            let _ = stream.set_write_timeout(Some(Duration::from_secs(2)));
            let id = self.id();
            self.conns.push(Conn {
                id,
                stream,
                input: Vec::new(),
                gone: false,
            });
        }
    }

    fn bus(&mut self) -> Result<(), String> {
        let Some(system) = &self.config.system else {
            return Ok(());
        };
        system
            .bus
            .dispatch()
            .map_err(|e| format!("the system bus went: {e}"))?;
        if system.sleep_coming() && !self.leaving {
            if self.loaded {
                eprintln!("nova-dictationd: the computer is going to sleep, the model is unloaded");
            }
            self.leaving = true;
        }
        Ok(())
    }

    fn conn(&mut self, id: u64) -> Option<&mut Conn> {
        self.conns.iter_mut().find(|c| c.id == id)
    }

    fn heard_from(&mut self, id: u64) {
        let Some(conn) = self.conn(id) else {
            return;
        };
        for line in conn.lines() {
            // Nothing more is heard from a connection that has ended.
            if self.conn(id).is_none_or(|c| c.gone) {
                break;
            }
            match line.as_str() {
                "start" => self.start(id),
                "finish" => self.finish(id),
                "cancel" => {
                    self.cancel(id);
                    if let Some(conn) = self.conn(id) {
                        conn.gone = true;
                    }
                }
                "status" => {
                    let status = self.status();
                    if let Some(conn) = self.conn(id) {
                        conn.say(&status);
                        conn.gone = true;
                    }
                }
                _ => {}
            }
        }
    }

    /// Connection <id> closed: a dictation still being said is forgotten,
    /// as a cancel; one let go is finished all the same, its words kept for
    /// `nova dictation last` (the shell may have gone; they are not lost).
    fn left(&mut self, id: u64) {
        if self
            .session
            .as_ref()
            .is_some_and(|s| s.conn == id && !s.finishing)
        {
            self.end();
        }
    }

    fn status(&self) -> String {
        let unload_in = if self.loaded && self.session.is_none() {
            self.config
                .idle
                .saturating_sub(self.idle_since.elapsed())
                .as_secs()
                .to_string()
        } else {
            "null".into()
        };
        format!(
            "{{\"type\":\"status\",\"loaded\":{},\"busy\":{},\"unload_in\":{unload_in}}}",
            self.loaded,
            self.session.is_some()
        )
    }

    fn refuse(&mut self, id: u64, reason: &str) {
        if let Some(conn) = self.conn(id) {
            conn.say(&error(reason));
            conn.gone = true;
        }
    }

    fn start(&mut self, id: u64) {
        if self.session.is_some() {
            return self.refuse(id, "busy");
        }
        if !self.config.engine {
            return self.refuse(id, "no-engine");
        }
        if !self.config.model.is_file() {
            return self.refuse(id, "no-model");
        }
        let recorder = match Recorder::spawn(&self.config.recorder) {
            Ok(recorder) => recorder,
            Err(e) => {
                eprintln!("nova-dictationd: could not record: {e}");
                return self.refuse(id, "microphone");
            }
        };
        let _ = self.worker.jobs.send(Job::Load);
        self.session = Some(Session {
            conn: id,
            dictation: Dictation::new(),
            recorder: Some(recorder),
            hearing: None,
            finishing: false,
            hold: None,
        });
        if let Some(conn) = self.conn(id) {
            conn.say("{\"type\":\"listening\"}");
        }
    }

    fn finish(&mut self, id: u64) {
        let Some(s) = self
            .session
            .as_mut()
            .filter(|s| s.conn == id && !s.finishing)
        else {
            return;
        };
        s.finishing = true;
        match s.recorder.as_mut() {
            Some(recorder) => recorder.stop(),
            None => self.recording_ended(),
        }
    }

    /// Ends the dictation of connection <id>, if it has one, with no words.
    fn cancel(&mut self, id: u64) {
        if self.session.as_ref().is_some_and(|s| s.conn == id) {
            self.end();
        }
    }

    fn end(&mut self) {
        if let Some(mut s) = self.session.take() {
            if let Some(h) = &s.hearing {
                h.stop.store(true, Ordering::Relaxed);
            }
            s.recorder = None;
            if let (Some(cookie), Some(system)) = (s.hold.take(), &self.config.system) {
                system.release(cookie);
            }
        }
        self.idle_since = Instant::now();
    }

    fn fail(&mut self, reason: &str) {
        if let Some(conn) = self.session.as_ref().map(|s| s.conn) {
            self.refuse(conn, reason);
        }
        self.end();
    }

    fn recorded(&mut self) {
        let Some(s) = self.session.as_mut() else {
            return;
        };
        let Some(recorder) = s.recorder.as_mut() else {
            return;
        };
        match recorder.read() {
            Some(samples) => {
                let room = s.dictation.push(&samples);
                if !room && !s.finishing {
                    // As long as a dictation may be: let go, as if the
                    // shell had (it does, at ten minutes).
                    let conn = s.conn;
                    self.finish(conn);
                } else if !s.finishing {
                    self.look_if_due();
                }
            }
            None => {
                if let Some(mut recorder) = s.recorder.take() {
                    let _ = recorder.child.wait();
                }
                self.recording_ended();
            }
        }
    }

    /// pw-record has ended: let go, or the microphone went.
    fn recording_ended(&mut self) {
        let Some(s) = self.session.as_mut() else {
            return;
        };
        if !s.finishing {
            return self.fail("microphone");
        }
        let next = s.dictation.finish();
        self.follow(next);
    }

    fn look_if_due(&mut self) {
        let Some(s) = self.session.as_mut() else {
            return;
        };
        if s.hearing.is_some() {
            return;
        }
        if let Some(window) = s.dictation.due() {
            // While the words go on, half the cores, cooler and quieter, and
            // as fast as speech comes; at a pause, all of them: the key is
            // often let go there, and the end then waits on this hearing.
            let threads = if window.paused {
                self.config.last_threads
            } else {
                self.config.look_threads
            };
            self.hear(window, threads);
        }
    }

    fn hear(&mut self, window: Window, threads: usize) {
        let id = self.id();
        let Some(s) = self.session.as_mut() else {
            return;
        };
        let stop = Arc::new(AtomicBool::new(false));
        let samples = s.dictation.samples(window);
        s.hearing = Some(Hearing {
            window,
            id,
            stop: stop.clone(),
        });
        let _ = self.worker.jobs.send(Job::Hear {
            id,
            samples,
            threads,
            stop,
        });
    }

    fn follow(&mut self, next: Next) {
        match next {
            Next::Nothing => {
                if self.session.as_ref().is_some_and(|s| !s.finishing) {
                    self.look_if_due();
                }
            }
            Next::Words(words) => self.deliver(&words),
            Next::Hear(window) => self.hear_last(window),
        }
    }

    /// The end, which someone is waiting on: on every core, and on battery
    /// with the CPU's clock held up (power saver keeps it low) for as long.
    fn hear_last(&mut self, window: Window) {
        let battery = system::on_battery(&self.config.supplies);
        let Some(s) = self.session.as_mut() else {
            return;
        };
        if let Some(h) = s.hearing.take() {
            h.stop.store(true, Ordering::Relaxed);
        }
        if battery && s.hold.is_none() {
            s.hold = self
                .config
                .system
                .as_ref()
                .and_then(System::hold_performance);
        }
        let threads = self.config.last_threads;
        self.hear(window, threads);
    }

    fn answers(&mut self) {
        let mut buf = [0u8; 64];
        let _ = (&self.worker.wake).read(&mut buf);
        while let Ok(done) = self.worker.done.try_recv() {
            match done {
                Done::Loaded(Ok(())) => {
                    if !self.loaded {
                        self.loaded = true;
                        if self.session.is_none() {
                            self.idle_since = Instant::now();
                        }
                    }
                }
                Done::Loaded(Err(e)) => {
                    eprintln!("nova-dictationd: {e}");
                    self.fail("engine");
                }
                Done::Heard { id, heard } => self.heard(id, heard),
            }
        }
    }

    fn heard(&mut self, id: u64, heard: Result<Vec<Token>, String>) {
        let Some(s) = self.session.as_mut() else {
            return;
        };
        // One given up on (stopped for the end) is no longer waited for.
        if s.hearing.as_ref().is_none_or(|h| h.id != id) {
            return;
        }
        let hearing = s.hearing.take().expect("the hearing waited for");
        let next = match heard {
            Ok(tokens) => s.dictation.heard(hearing.window, &tokens),
            Err(e) if hearing.window.last => {
                eprintln!("nova-dictationd: the end could not be heard: {e}");
                return self.fail("engine");
            }
            Err(_) => s.dictation.dropped(hearing.window),
        };
        self.follow(next);
    }

    fn deliver(&mut self, words: &str) {
        let Some(conn) = self.session.as_ref().map(|s| s.conn) else {
            return;
        };
        let text = tidy::clean(words, &Vocab::read(&self.config.vocab));
        if !text.is_empty() {
            if let Err(e) = keep_last(&self.config.runtime, &text) {
                eprintln!("nova-dictationd: could not keep the last words: {e}");
            }
        }
        if let Some(conn) = self.conn(conn) {
            conn.say(&format!("{{\"type\":\"text\",\"text\":{}}}", quote(&text)));
            conn.gone = true;
        }
        self.end();
    }
}
