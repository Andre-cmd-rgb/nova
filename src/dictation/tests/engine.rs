//! A speech engine of another whisper.cpp release than the one the daemon's
//! declarations follow is no engine (engine.rs, VERSION): never handed a
//! struct it would read otherwise. The engine here is a library of the
//! test's own, made with rustc, that has libparakeet's every function the
//! daemon looks up and says the version it is told; only its version is
//! ever called. Each test has folders of its own; nothing reaches the
//! user's session, nor the system bus.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};
use std::time::{Duration, Instant};

use nova_dictation::engine::VERSION;

const DAEMON: &str = env!("CARGO_BIN_EXE_nova-dictationd");

const FAKE: &str = r#"
use std::ffi::{c_char, CString};
#[no_mangle]
pub extern "C" fn parakeet_version() -> *const c_char {
    let v = std::env::var("NOVA_TEST_ENGINE_VERSION").unwrap_or_default();
    CString::new(v).unwrap().into_raw()
}
macro_rules! never { ($($name:ident)*) => { $(
    #[no_mangle]
    pub extern "C" fn $name() { std::process::abort() }
)* } }
never!(ggml_backend_load_all parakeet_log_set parakeet_context_default_params
    parakeet_init_from_file_with_params parakeet_free parakeet_full_default_params
    parakeet_full parakeet_full_n_segments parakeet_full_n_tokens
    parakeet_full_get_token_data parakeet_token_to_str);
"#;

/// A scratch folder, and the engine made in it.
fn engine() -> (PathBuf, PathBuf) {
    let dir = nova_sd::testing::scratch("dictation-engine");
    let source = dir.join("fake.rs");
    std::fs::write(&source, FAKE).unwrap();
    let library = dir.join("libparakeet.so.1");
    let rustc = std::env::var("RUSTC").unwrap_or_else(|_| "rustc".into());
    let made = Command::new(rustc)
        .args(["--crate-type", "cdylib", "--edition", "2021", "-o"])
        .arg(&library)
        .arg(&source)
        .output()
        .expect("rustc, to make the test's engine");
    assert!(
        made.status.success(),
        "{}",
        String::from_utf8_lossy(&made.stderr)
    );
    (dir, library)
}

fn daemon(dir: &Path, library: &Path, version: &str) -> Command {
    let mut command = Command::new(DAEMON);
    command
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .env("HOME", dir.join("home"))
        .env("XDG_RUNTIME_DIR", dir.join("run"))
        .env("XDG_DATA_HOME", dir.join("data"))
        .env("XDG_CONFIG_HOME", dir.join("config"))
        .env(
            "DBUS_SYSTEM_BUS_ADDRESS",
            "unix:path=/nonexistent/nova-test-bus",
        )
        .env("NOVA_POWER_SUPPLIES", dir.join("supplies"))
        .env("NOVA_DICTATION_RECORDER", "false")
        .env("NOVA_DICTATION_LIBRARY", library)
        .env("NOVA_TEST_ENGINE_VERSION", version)
        .stdin(Stdio::null());
    command
}

fn checked(dir: &Path, library: &Path, version: &str) -> Output {
    daemon(dir, library, version)
        .arg("--engine")
        .output()
        .unwrap()
}

#[test]
fn only_the_release_the_daemon_was_written_for_is_an_engine() {
    let (dir, library) = engine();
    for version in [VERSION.to_owned(), format!("{VERSION}-dev")] {
        let out = checked(&dir, &library, &version);
        assert!(out.status.success(), "{version}: {out:?}");
        assert!(out.stderr.is_empty() && out.stdout.is_empty(), "{out:?}");
    }
    for version in ["1.9.6", "1.10.0", "2.0.0", ""] {
        let out = checked(&dir, &library, version);
        assert_eq!(out.status.code(), Some(1), "{version}: {out:?}");
        let why = String::from_utf8_lossy(&out.stderr);
        assert!(
            why.contains(&format!(
                "is whisper.cpp {version:?}, and dictation is made for {VERSION}"
            )),
            "{why}"
        );
    }
    // Not a library at all, or none.
    std::fs::write(dir.join("not-a-library"), "x").unwrap();
    for path in [dir.join("not-a-library"), dir.join("none")] {
        let out = checked(&dir, &path, VERSION);
        assert_eq!(out.status.code(), Some(1), "{out:?}");
        assert!(
            String::from_utf8_lossy(&out.stderr).contains("no speech engine"),
            "{out:?}"
        );
    }
    let _ = std::fs::remove_dir_all(&dir);
}

struct Running(Child);

impl Drop for Running {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

// A dictation on an engine of another release is answered no-engine, as
// where there is none, and the journal (stderr) says why.
#[test]
fn a_dictation_on_an_engine_of_another_release_is_answered_no_engine() {
    let (dir, library) = engine();
    let model = dir.join("data/nova-dictation/ggml-parakeet-tdt-0.6b-v3-q8_0.bin");
    std::fs::create_dir_all(model.parent().unwrap()).unwrap();
    std::fs::write(&model, "a model").unwrap();
    std::fs::create_dir_all(dir.join("supplies")).unwrap();
    let socket = dir.join("dictation.sock");
    let log = std::fs::File::create(dir.join("journal")).unwrap();
    let running = Running(
        daemon(&dir, &library, "1.10.0")
            .arg("--socket")
            .arg(&socket)
            .stderr(log)
            .spawn()
            .unwrap(),
    );
    let started = Instant::now();
    let stream = loop {
        if let Ok(stream) = UnixStream::connect(&socket) {
            break stream;
        }
        assert!(started.elapsed() < Duration::from_secs(10), "no socket");
        std::thread::sleep(Duration::from_millis(20));
    };
    stream
        .set_read_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    (&stream).write_all(b"start\n").unwrap();
    let mut line = String::new();
    BufReader::new(&stream).read_line(&mut line).unwrap();
    assert_eq!(line.trim_end(), r#"{"type":"error","error":"no-engine"}"#);
    drop(running);
    let journal = std::fs::read_to_string(dir.join("journal")).unwrap();
    assert!(
        journal.contains(&format!(
            "is whisper.cpp \"1.10.0\", and dictation is made for {VERSION}"
        )),
        "{journal}"
    );
    let _ = std::fs::remove_dir_all(&dir);
}
