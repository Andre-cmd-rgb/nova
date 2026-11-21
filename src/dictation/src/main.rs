// nova-dictationd: Nova's dictation, speech to text on this computer's CPU,
// heard while it is said (src/dictation, docs/ARCHITECTURE.md).
//
//   nova-dictationd                     serves the shell on
//                                       $XDG_RUNTIME_DIR/nova/dictation.sock,
//                                       the socket systemd hands it
//                                       (nova-dictationd.socket) or its own
//   nova-dictationd --socket <path>     on a socket of its own there
//   nova-dictationd --hear <rec.pcm>    dictates a recording (raw 16 kHz mono
//                                       16-bit) as fast as it can, and prints
//                                       its words
//   nova-dictationd --play <rec.pcm> [<speed>]
//                                       a microphone for tests: plays the
//                                       recording on stdout at its own pace
//                                       (or <speed> times it), then silence,
//                                       until it is stopped
//
// For tests: NOVA_DICTATION_RECORDER (what records, in pw-record's place),
// NOVA_DICTATION_LIBRARY (the speech engine), NOVA_DICTATION_IDLE (seconds
// the model stays loaded), NOVA_POWER_SUPPLIES.

use std::io::Write;
use std::os::fd::FromRawFd;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::AtomicBool;
use std::time::{Duration, Instant};

use nova_dictation::dictation::{Dictation, Next};
use nova_dictation::engine::{Ear, Engine, LIBRARY, RATE};
use nova_dictation::server::{Config, Server};
use nova_dictation::system::{self, Pressure, System};
use nova_dictation::tidy;
use nova_dictation::vocab::Vocab;

/// The model `nova dictation setup` downloads, where it puts it.
const MODEL: &str = "nova-dictation/ggml-parakeet-tdt-0.6b-v3-q8_0.bin";
/// How long the model stays loaded after the last dictation. Its load (a
/// tenth of a second, here) happens while the first words are said, so
/// keeping it longer buys little, and it is 700 MB of memory.
const IDLE: Duration = Duration::from_secs(120);

fn fail(e: impl std::fmt::Display) -> ! {
    eprintln!("nova-dictationd: {e}");
    std::process::exit(1);
}

fn env_dir(name: &str, under_home: &str) -> PathBuf {
    std::env::var_os(name)
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(under_home)))
        .unwrap_or_else(|| fail(format!("no ${name} and no $HOME")))
}

fn read_recording(path: &str) -> Vec<i16> {
    let bytes = std::fs::read(path).unwrap_or_else(|e| fail(format!("{path}: {e}")));
    bytes
        .as_chunks::<2>()
        .0
        .iter()
        .map(|&b| i16::from_le_bytes(b))
        .collect()
}

/// The socket systemd passed (LISTEN_FDS, as fd 3), else one of its own.
fn listener(path: Option<&str>, runtime: &Path) -> UnixListener {
    extern "C" {
        fn fcntl(fd: i32, cmd: i32, ...) -> i32;
    }
    let ours = std::env::var("LISTEN_PID")
        .ok()
        .and_then(|p| p.parse::<u32>().ok())
        == Some(std::process::id());
    let fds = std::env::var("LISTEN_FDS")
        .ok()
        .and_then(|n| n.parse::<u32>().ok())
        .unwrap_or(0);
    std::env::remove_var("LISTEN_PID");
    std::env::remove_var("LISTEN_FDS");
    std::env::remove_var("LISTEN_FDNAMES");
    if path.is_none() && ours && fds >= 1 {
        // SAFETY: fd 3 is the socket systemd passed, ours from now on; it is
        // kept from what this starts (pw-record).
        unsafe {
            fcntl(3, 2 /* F_SETFD */, 1 /* FD_CLOEXEC */);
            return UnixListener::from_raw_fd(3);
        }
    }
    let path = path
        .map(PathBuf::from)
        .unwrap_or_else(|| runtime.join("dictation.sock"));
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).unwrap_or_else(|e| fail(format!("{}: {e}", dir.display())));
    }
    // One left by a daemon that is gone is taken over; a live one is not.
    if UnixStream::connect(&path).is_ok() {
        fail(format!("{} is in use", path.display()));
    }
    let _ = std::fs::remove_file(&path);
    let listener =
        UnixListener::bind(&path).unwrap_or_else(|e| fail(format!("{}: {e}", path.display())));
    let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
    listener
}

fn serve(socket: Option<&str>) {
    let runtime_root = PathBuf::from(
        std::env::var_os("XDG_RUNTIME_DIR").unwrap_or_else(|| fail("no $XDG_RUNTIME_DIR")),
    );
    let runtime = runtime_root.join("nova");
    let listener = listener(socket, &runtime);
    let model = env_dir("XDG_DATA_HOME", ".local/share").join(MODEL);
    let library = std::env::var("NOVA_DICTATION_LIBRARY").unwrap_or_else(|_| LIBRARY.to_owned());
    let recorder: Vec<String> = match std::env::var("NOVA_DICTATION_RECORDER") {
        Ok(command) => command.split_whitespace().map(str::to_owned).collect(),
        Err(_) => [
            "pw-record",
            "--raw",
            "--rate",
            "16000",
            "--channels",
            "1",
            "--format",
            "s16",
            "-P",
            "{ application.name = \"Nova Dictation\" }",
            "-",
        ]
        .map(str::to_owned)
        .to_vec(),
    };
    let idle = std::env::var("NOVA_DICTATION_IDLE")
        .ok()
        .and_then(|s| s.parse::<f64>().ok())
        .map_or(IDLE, Duration::from_secs_f64);
    let cores = system::cores();
    let config = Config {
        engine: Path::new(&library).exists(),
        model: model.clone(),
        recorder,
        runtime: runtime.join("dictation"),
        vocab: env_dir("XDG_CONFIG_HOME", ".config").join("nova/dictation/vocab.toml"),
        supplies: std::env::var_os("NOVA_POWER_SUPPLIES")
            .map_or_else(|| PathBuf::from("/sys/class/power_supply"), PathBuf::from),
        idle,
        // While it is said: half the cores, cooler and quieter, and as fast
        // as speech comes; the end, which someone waits on, on all of them.
        look_threads: cores.div_ceil(2).max(1),
        last_threads: cores,
        system: System::connect().ok(),
        pressure: Pressure::watch(),
    };
    let load = Box::new(move || -> Result<Box<dyn Ear>, String> {
        let started = Instant::now();
        let engine = Engine::load(&library, &model)?;
        eprintln!(
            "nova-dictationd: the model is loaded, in {} ms, on {}",
            started.elapsed().as_millis(),
            Engine::backend().unwrap_or_else(|| "no CPU backend that could be named".into())
        );
        Ok(Box::new(engine))
    });
    let server = Server::new(config, listener, load).unwrap_or_else(|e| fail(e));
    if let Err(e) = server.run() {
        fail(e);
    }
}

/// Dictates <path> as fast as it can: what `nova-dictationd` would paste.
fn hear(path: &str) {
    let model = env_dir("XDG_DATA_HOME", ".local/share").join(MODEL);
    let library = std::env::var("NOVA_DICTATION_LIBRARY").unwrap_or_else(|_| LIBRARY.to_owned());
    let mut engine = Engine::load(&library, &model).unwrap_or_else(|e| fail(e));
    let cores = system::cores();
    let stop = AtomicBool::new(false);
    let mut dictation = Dictation::new();
    for chunk in read_recording(path).chunks(RATE / 50) {
        dictation.push(chunk);
        if let Some(window) = dictation.due() {
            let tokens = engine
                .hear(&dictation.samples(window), cores.div_ceil(2), &stop)
                .unwrap_or_else(|e| fail(e));
            dictation.heard(window, &tokens);
        }
    }
    let words = match dictation.finish() {
        Next::Words(words) => words,
        Next::Hear(window) => {
            let tokens = engine
                .hear(&dictation.samples(window), cores, &stop)
                .unwrap_or_else(|e| fail(e));
            match dictation.heard(window, &tokens) {
                Next::Words(words) => words,
                _ => String::new(),
            }
        }
        Next::Nothing => String::new(),
    };
    let vocab =
        Vocab::read(&env_dir("XDG_CONFIG_HOME", ".config").join("nova/dictation/vocab.toml"));
    println!("{}", tidy::clean(&words, &vocab).trim_end());
}

/// Plays <path> on stdout at its own pace (<speed> times it), 20 ms at a
/// time, then silence, as pw-record would from a microphone, until it is
/// stopped.
fn play(path: &str, speed: f64) {
    let samples = read_recording(path);
    let frame = RATE / 50;
    let silence = vec![0i16; frame];
    let mut out = std::io::stdout().lock();
    let started = Instant::now();
    for (n, chunk) in samples
        .chunks(frame)
        .chain(std::iter::repeat(silence.as_slice()))
        .enumerate()
    {
        let due = started + Duration::from_secs_f64(0.02 * n as f64 / speed);
        if let Some(wait) = due.checked_duration_since(Instant::now()) {
            std::thread::sleep(wait);
        }
        let bytes: Vec<u8> = chunk.iter().flat_map(|s| s.to_le_bytes()).collect();
        if out.write_all(&bytes).and_then(|()| out.flush()).is_err() {
            return;
        }
    }
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args
        .iter()
        .map(String::as_str)
        .collect::<Vec<_>>()
        .as_slice()
    {
        [] => serve(None),
        ["--socket", path] => serve(Some(path)),
        ["--hear", path] => hear(path),
        ["--play", path] => play(path, 1.0),
        ["--play", path, speed] => match speed.parse::<f64>() {
            Ok(speed) if speed > 0.0 => play(path, speed),
            _ => fail(format!("{speed}: not a speed")),
        },
        _ => {
            eprintln!("usage: nova-dictationd [--socket <path> | --hear <recording.pcm> | --play <recording.pcm> [<speed>]]");
            std::process::exit(2);
        }
    }
}
