//! The daemon as the shell sees it: its socket, a microphone that plays a
//! recording (nova-dictationd --play), and an engine that hears tones as
//! words, so that what is tested is the daemon and not the model. Each test
//! has folders of its own; nothing reaches the user's session.

use std::io::{BufRead, BufReader, ErrorKind, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Arc;
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use nova_dictation::engine::{Ear, Token, RATE};
use nova_dictation::server::{Config, Server, MOST_CONNECTIONS, QUIET};

/// Hears each stretch of sound as a word, by its length (a second is
/// "Hello", less is "world"), with a full stop after the last.
struct Tones;

impl Ear for Tones {
    fn hear(&mut self, samples: &[f32], _: usize, stop: &AtomicBool) -> Result<Vec<Token>, String> {
        if stop.load(Ordering::Relaxed) {
            return Err("stopped".into());
        }
        let frame = RATE / 50;
        let loud: Vec<bool> = samples
            .chunks(frame)
            .map(|f| (f.iter().map(|s| s * s).sum::<f32>() / f.len() as f32).sqrt() > 0.01)
            .collect();
        let mut tokens = Vec::new();
        let mut start = None;
        for (i, &l) in loud.iter().chain([&false]).enumerate() {
            match (l, start) {
                (true, None) => start = Some(i),
                (false, Some(s)) => {
                    let word = if i - s >= 45 { "▁Hello" } else { "▁world" };
                    tokens.push(Token {
                        text: word.into(),
                        t0: (s * 2) as i64,
                        t1: (i * 2) as i64,
                        word_start: true,
                    });
                    start = None;
                }
                _ => {}
            }
        }
        if let Some(last) = tokens.last() {
            let t = last.t1;
            tokens.push(Token {
                text: ".".into(),
                t0: t,
                t1: t,
                word_start: false,
            });
        }
        Ok(tokens)
    }
}

/// <seconds> of a 220 Hz tone at -22 dBFS, or of silence.
fn tone(seconds: f64, on: bool) -> Vec<i16> {
    let n = (seconds * RATE as f64) as usize;
    (0..n)
        .map(|i| {
            if on {
                (2600.0 * (2.0 * std::f64::consts::PI * 220.0 * i as f64 / RATE as f64).sin())
                    as i16
            } else {
                0
            }
        })
        .collect()
}

/// "Hello" (a second), a pause, "world" (0.6 s), and the quiet after.
fn hello_world() -> Vec<i16> {
    [
        tone(0.4, false),
        tone(1.0, true),
        tone(0.8, false),
        tone(0.6, true),
        tone(0.8, false),
    ]
    .concat()
}

struct Setup {
    model: bool,
    engine: bool,
    loads: bool,
    recorder: Option<Vec<String>>,
    idle: Duration,
    vocab: Option<&'static str>,
    /// What a client wrote before the daemon served, and then went: as
    /// systemd's socket holds it while the daemon is still starting.
    early: Option<&'static str>,
}

impl Default for Setup {
    fn default() -> Setup {
        Setup {
            model: true,
            engine: true,
            loads: true,
            recorder: None,
            idle: Duration::from_secs(30),
            vocab: None,
            early: None,
        }
    }
}

struct Daemon {
    dir: PathBuf,
    socket: PathBuf,
    loads: Arc<AtomicUsize>,
    server: Option<JoinHandle<Result<(), String>>>,
}

impl Daemon {
    fn start(setup: Setup) -> Daemon {
        let dir = nova_sd::testing::scratch("dictation");
        let recording = dir.join("hello.pcm");
        let bytes: Vec<u8> = hello_world().iter().flat_map(|s| s.to_le_bytes()).collect();
        std::fs::write(&recording, bytes).unwrap();
        let model = dir.join("model.bin");
        if setup.model {
            std::fs::write(&model, b"a model").unwrap();
        }
        let vocab = dir.join("config/nova/dictation/vocab.toml");
        if let Some(text) = setup.vocab {
            std::fs::create_dir_all(vocab.parent().unwrap()).unwrap();
            std::fs::write(&vocab, text).unwrap();
        }
        std::fs::create_dir_all(dir.join("supplies")).unwrap();
        let socket = dir.join("dictation.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        // The player says who it is (exec keeps the shell's pid), so that a
        // test can see whether the microphone is still open.
        let recorder = setup.recorder.unwrap_or_else(|| {
            vec![
                "sh".into(),
                "-c".into(),
                "echo $$ >\"$0\"; exec \"$@\"".into(),
                dir.join("recorder.pid").display().to_string(),
                env!("CARGO_BIN_EXE_nova-dictationd").into(),
                "--play".into(),
                recording.display().to_string(),
                "20".into(),
            ]
        });
        if let Some(early) = setup.early {
            let mut client = UnixStream::connect(&socket).unwrap();
            client.write_all(early.as_bytes()).unwrap();
        }
        let (runtime, supplies) = (dir.join("run/nova/dictation"), dir.join("supplies"));
        let (engine, idle) = (setup.engine, setup.idle);
        // The system bus is not Send: the server is made on its own thread.
        let config = move || Config {
            model,
            engine,
            recorder,
            runtime,
            vocab,
            supplies,
            idle,
            look_threads: 1,
            last_threads: 1,
            system: None,
            pressure: None,
        };
        let loads = Arc::new(AtomicUsize::new(0));
        let counted = loads.clone();
        let works = setup.loads;
        let load = Box::new(move || -> Result<Box<dyn Ear>, String> {
            counted.fetch_add(1, Ordering::Relaxed);
            if works {
                Ok(Box::new(Tones))
            } else {
                Err("the model would not load".into())
            }
        });
        let server = thread::spawn(move || Server::new(config(), listener, load).unwrap().run());
        Daemon {
            dir,
            socket,
            loads,
            server: Some(server),
        }
    }

    fn connect(&self) -> Shell {
        let stream = UnixStream::connect(&self.socket).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(10)))
            .unwrap();
        Shell {
            reader: BufReader::new(stream.try_clone().unwrap()),
            stream,
        }
    }

    fn last(&self) -> PathBuf {
        self.dir.join("run/nova/dictation/last")
    }

    /// The pid of the last recorder started, if one was (it says so at once).
    fn recorder(&self) -> Option<u32> {
        let started = Instant::now();
        while started.elapsed() < Duration::from_secs(1) {
            let read = std::fs::read_to_string(self.dir.join("recorder.pid"));
            if let Some(pid) = read.ok().and_then(|s| s.trim().parse().ok()) {
                return Some(pid);
            }
            thread::sleep(Duration::from_millis(20));
        }
        None
    }

    /// Whether the recorder <pid> has ended within <limit>, and is reaped.
    fn recorder_ended_within(&self, pid: u32, limit: Duration) -> bool {
        let started = Instant::now();
        while started.elapsed() < limit {
            if !Path::new(&format!("/proc/{pid}")).exists() {
                return true;
            }
            thread::sleep(Duration::from_millis(20));
        }
        false
    }

    fn status(&self) -> String {
        let mut status = self.connect();
        status.say("status");
        status.hear().unwrap()
    }

    /// Waits for the daemon to end by itself, up to <limit>; how long it took.
    fn ended_within(&mut self, limit: Duration) -> Option<Duration> {
        let started = Instant::now();
        while started.elapsed() < limit {
            if self.server.as_ref().is_some_and(JoinHandle::is_finished) {
                self.server.take().unwrap().join().unwrap().unwrap();
                return Some(started.elapsed());
            }
            thread::sleep(Duration::from_millis(20));
        }
        None
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

struct Shell {
    stream: UnixStream,
    reader: BufReader<UnixStream>,
}

impl Shell {
    fn say(&mut self, line: &str) {
        self.stream
            .write_all(format!("{line}\n").as_bytes())
            .unwrap();
    }

    /// Whether the daemon still holds the connection: no line, and not
    /// closed, for a tenth of a second.
    fn open(&mut self) -> bool {
        let wait = |shell: &Shell, time| shell.stream.set_read_timeout(Some(time)).unwrap();
        wait(self, Duration::from_millis(100));
        let mut line = String::new();
        let open = matches!(
            self.reader.read_line(&mut line),
            Err(e) if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut)
        );
        wait(self, Duration::from_secs(10));
        open
    }

    /// The daemon's next line; none once it has closed the connection.
    fn hear(&mut self) -> Option<String> {
        let mut line = String::new();
        match self.reader.read_line(&mut line) {
            Ok(0) => None,
            Ok(_) => Some(line.trim_end().to_owned()),
            Err(e) => panic!("no answer: {e}"),
        }
    }

    /// Starts a dictation, waits for the recording to be played, lets go.
    fn dictate(&mut self) -> Option<String> {
        self.say("start");
        assert_eq!(self.hear().as_deref(), Some(r#"{"type":"listening"}"#));
        thread::sleep(Duration::from_millis(400));
        self.say("finish");
        self.hear()
    }
}

#[test]
fn the_words_come_when_let_go_and_are_kept_for_last_for_this_user_alone() {
    let daemon = Daemon::start(Setup::default());
    let mut shell = daemon.connect();
    assert_eq!(
        shell.dictate().as_deref(),
        Some(r#"{"type":"text","text":"Hello world. "}"#)
    );
    assert_eq!(shell.hear(), None, "one connection is one dictation");
    assert_eq!(
        std::fs::read_to_string(daemon.last()).unwrap(),
        "Hello world. "
    );
    let mode = |p: &Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode(&daemon.last()), 0o600);
    assert_eq!(mode(daemon.last().parent().unwrap()), 0o700);
    // And again, on the model already loaded.
    assert_eq!(
        daemon.connect().dictate().as_deref(),
        Some(r#"{"type":"text","text":"Hello world. "}"#)
    );
    assert_eq!(daemon.loads.load(Ordering::Relaxed), 1);
}

#[test]
fn the_users_spellings_are_used() {
    let daemon = Daemon::start(Setup {
        vocab: Some("hello = \"Hullo\"\n\"world\" = \"World\"\n"),
        ..Setup::default()
    });
    assert_eq!(
        daemon.connect().dictate().as_deref(),
        Some(r#"{"type":"text","text":"Hullo World. "}"#)
    );
}

#[test]
fn without_the_model_or_the_engine_it_says_so() {
    for (setup, error) in [
        (
            Setup {
                model: false,
                ..Setup::default()
            },
            "no-model",
        ),
        (
            Setup {
                engine: false,
                ..Setup::default()
            },
            "no-engine",
        ),
        (
            Setup {
                loads: false,
                ..Setup::default()
            },
            "engine",
        ),
    ] {
        let daemon = Daemon::start(setup);
        let mut shell = daemon.connect();
        shell.say("start");
        let mut lines = vec![];
        while let Some(line) = shell.hear() {
            lines.push(line);
        }
        assert_eq!(
            lines.last().map(String::as_str),
            Some(format!(r#"{{"type":"error","error":"{error}"}}"#).as_str()),
            "{lines:?}"
        );
    }
}

#[test]
fn a_microphone_that_fails_or_goes_is_said() {
    for recorder in [
        vec!["/nonexistent/pw-record".to_owned()],
        vec!["false".to_owned()],
    ] {
        let daemon = Daemon::start(Setup {
            recorder: Some(recorder),
            ..Setup::default()
        });
        let mut shell = daemon.connect();
        shell.say("start");
        let mut lines = vec![];
        while let Some(line) = shell.hear() {
            lines.push(line);
        }
        assert_eq!(
            lines.last().map(String::as_str),
            Some(r#"{"type":"error","error":"microphone"}"#)
        );
    }
}

#[test]
fn one_dictation_at_a_time() {
    let daemon = Daemon::start(Setup::default());
    let mut first = daemon.connect();
    first.say("start");
    assert_eq!(first.hear().as_deref(), Some(r#"{"type":"listening"}"#));
    let mut second = daemon.connect();
    second.say("start");
    assert_eq!(
        second.hear().as_deref(),
        Some(r#"{"type":"error","error":"busy"}"#)
    );
    thread::sleep(Duration::from_millis(400));
    first.say("finish");
    assert_eq!(
        first.hear().as_deref(),
        Some(r#"{"type":"text","text":"Hello world. "}"#)
    );
}

#[test]
fn a_cancel_or_a_closed_connection_forgets_it() {
    let daemon = Daemon::start(Setup::default());
    let mut shell = daemon.connect();
    shell.say("start");
    assert_eq!(shell.hear().as_deref(), Some(r#"{"type":"listening"}"#));
    thread::sleep(Duration::from_millis(400));
    shell.say("cancel");
    assert_eq!(shell.hear(), None);
    let mut shell = daemon.connect();
    shell.say("start");
    assert_eq!(shell.hear().as_deref(), Some(r#"{"type":"listening"}"#));
    drop(shell);
    thread::sleep(Duration::from_millis(400));
    assert!(!daemon.last().exists(), "nothing kept");
    let mut status = daemon.connect();
    status.say("status");
    let line = status.hear().unwrap();
    assert!(line.contains(r#""busy":false"#), "{line}");
}

// However a connection ends while its lines are handled (the client gone
// before "listening" could be said: the shell restarted right after Super+D;
// a line after one that ends it, in the same write), the dictation it owned
// ends with it: the microphone closes, and the next is not refused as busy.
#[test]
fn a_connection_that_ends_while_its_lines_are_handled_leaves_no_dictation_behind() {
    let mut wrong = vec![];
    for (early, write) in [
        (Some("start\n"), None),
        (None, Some("status\nstart\n")),
        (None, Some("cancel\nstart\n")),
        (None, Some("start\nstart\n")),
    ] {
        let daemon = Daemon::start(Setup {
            early,
            ..Setup::default()
        });
        let case = early.or(write).unwrap();
        if let Some(write) = write {
            // Until the daemon closes it.
            let mut shell = daemon.connect();
            shell.stream.write_all(write.as_bytes()).unwrap();
            while shell.hear().is_some() {}
        }
        if let Some(pid) = daemon.recorder() {
            if !daemon.recorder_ended_within(pid, Duration::from_secs(3)) {
                wrong.push(format!("{case:?}: the microphone is still open"));
            }
        }
        let status = daemon.status();
        if !status.contains(r#""busy":false"#) {
            wrong.push(format!("{case:?}: {status}"));
        }
        let mut next = daemon.connect();
        next.say("start");
        let answer = next.hear();
        if answer.as_deref() != Some(r#"{"type":"listening"}"#) {
            wrong.push(format!("{case:?}: a new dictation is answered {answer:?}"));
        }
    }
    assert!(wrong.is_empty(), "{wrong:#?}");
}

// pw-record that closes its output when stopped but does not end (hung in
// its teardown) does not hold up the words, nor the daemon: it is ended.
#[test]
fn a_recorder_that_closes_its_output_and_hangs_is_ended() {
    let dir = nova_sd::testing::scratch("dictation-recorder");
    let recording = dir.join("hello.pcm");
    let bytes: Vec<u8> = hello_world().iter().flat_map(|s| s.to_le_bytes()).collect();
    std::fs::write(&recording, bytes).unwrap();
    let pid = dir.join("recorder.pid");
    let script = "echo $$ >\"$0\"; trap 'exec 1>&-; exec sleep 30' TERM; cat \"$1\"; while :; do sleep 0.05; done";
    let daemon = Daemon::start(Setup {
        recorder: Some(vec![
            "sh".into(),
            "-c".into(),
            script.into(),
            pid.display().to_string(),
            recording.display().to_string(),
        ]),
        ..Setup::default()
    });
    let started = Instant::now();
    assert_eq!(
        daemon.connect().dictate().as_deref(),
        Some(r#"{"type":"text","text":"Hello world. "}"#)
    );
    assert!(
        started.elapsed() < Duration::from_secs(5),
        "{:?}",
        started.elapsed()
    );
    let pid: u32 = std::fs::read_to_string(&pid)
        .unwrap()
        .trim()
        .parse()
        .unwrap();
    assert!(daemon.recorder_ended_within(pid, Duration::from_secs(3)));
    let _ = std::fs::remove_dir_all(&dir);
}

// The shell may go (restarted, say) once the key is let go: the words are
// not lost, but kept for `nova dictation last`.
#[test]
fn let_go_and_then_gone_the_words_are_still_kept() {
    let daemon = Daemon::start(Setup::default());
    let mut shell = daemon.connect();
    shell.say("start");
    assert_eq!(shell.hear().as_deref(), Some(r#"{"type":"listening"}"#));
    thread::sleep(Duration::from_millis(400));
    shell.say("finish");
    drop(shell);
    let started = Instant::now();
    while !daemon.last().exists() && started.elapsed() < Duration::from_secs(5) {
        thread::sleep(Duration::from_millis(20));
    }
    assert_eq!(
        std::fs::read_to_string(daemon.last()).unwrap(),
        "Hello world. "
    );
}

#[test]
fn the_model_is_unloaded_and_the_process_gone_once_unused() {
    let mut daemon = Daemon::start(Setup {
        idle: Duration::from_millis(600),
        ..Setup::default()
    });
    assert!(daemon.connect().dictate().unwrap().contains("Hello world."));
    let mut status = daemon.connect();
    status.say("status");
    let line = status.hear().unwrap();
    assert!(
        line.starts_with(r#"{"type":"status","loaded":true,"busy":false,"unload_in":"#),
        "{line}"
    );
    drop(status);
    let took = daemon.ended_within(Duration::from_secs(5)).expect("gone");
    assert!(took < Duration::from_secs(2), "{took:?}");
}

// A connection is for a dictation: one that holds none (silent, or done
// with its status) is closed after a few seconds, one that says what the
// daemon does not know at once, so that none keeps the model loaded, nor
// the process there past a sleep or a shortage of memory; and however many
// there are, the shell's next one gets in.
#[test]
fn a_connection_with_no_dictation_does_not_keep_the_daemon() {
    let mut daemon = Daemon::start(Setup {
        idle: Duration::from_millis(600),
        ..Setup::default()
    });
    assert!(daemon.connect().dictate().unwrap().contains("Hello world."));
    let mut unknown = daemon.connect();
    unknown.say("hello?");
    assert_eq!(unknown.hear(), None, "closed at once");
    let mut silent = daemon.connect();
    let started = Instant::now();
    assert_eq!(silent.hear(), None, "closed after a while");
    let took = started.elapsed();
    assert!(took < Duration::from_secs(5), "{took:?}");
    let took = daemon.ended_within(Duration::from_secs(5)).expect("gone");
    assert!(took < Duration::from_secs(2), "{took:?}");
}

#[test]
fn however_many_connections_wait_the_next_dictation_gets_in() {
    let daemon = Daemon::start(Setup::default());
    let waiting: Vec<Shell> = (0..64).map(|_| daemon.connect()).collect();
    let mut shell = daemon.connect();
    assert_eq!(
        shell.dictate().as_deref(),
        Some(r#"{"type":"text","text":"Hello world. "}"#)
    );
    // The oldest made room for it.
    let mut first = waiting.into_iter().next().unwrap();
    assert_eq!(first.hear(), None);
}

// Past MOST_CONNECTIONS the oldest waiting is closed as the next comes in,
// not at QUIET, when any that holds no dictation is: twice as many wait,
// and the older half is closed well inside it, the newer half still open.
#[test]
fn past_the_most_connections_the_oldest_waiting_are_closed_at_once() {
    let daemon = Daemon::start(Setup::default());
    let started = Instant::now();
    let mut waiting: Vec<Shell> = (0..2 * MOST_CONNECTIONS)
        .map(|_| daemon.connect())
        .collect();
    let (older, newer) = waiting.split_at_mut(MOST_CONNECTIONS);
    for shell in older {
        assert_eq!(shell.hear(), None);
    }
    let took = started.elapsed();
    assert!(took < QUIET / 3, "the oldest closed after {took:?}");
    for shell in newer {
        assert!(shell.open(), "a newer one closed");
    }
}

#[test]
fn with_nothing_loaded_it_does_not_stay() {
    let mut daemon = Daemon::start(Setup::default());
    let mut status = daemon.connect();
    status.say("status");
    assert_eq!(
        status.hear().as_deref(),
        Some(r#"{"type":"status","loaded":false,"busy":false,"unload_in":null}"#)
    );
    drop(status);
    assert!(daemon.ended_within(Duration::from_secs(5)).is_some());
    assert_eq!(daemon.loads.load(Ordering::Relaxed), 0);
}
