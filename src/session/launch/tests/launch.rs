//! nova-launch against a systemd of the test's own: a fake
//! org.freedesktop.systemd1 Manager on a private bus, which keeps the calls
//! of StartTransientUnit and answers with the job's end. Nothing here is
//! the user's session bus: every run is given the private bus's address,
//! and the apps are scripts in a scratch folder.

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use nova_sd::poll::{poll, sooner};
use nova_sd::testing::{scratch, PrivateBus};
use nova_sd::{Bus, Error, Interface, Message, Value};

const BIN: &str = env!("CARGO_BIN_EXE_nova-launch");
const MANAGER: &str = "org.freedesktop.systemd1.Manager";

type Calls = Arc<Mutex<Vec<Vec<Value>>>>;

/// How the fake systemd answers.
#[derive(Clone, Copy, PartialEq)]
enum Answer {
    /// A job that ends as "done", signalled before the answer is sent.
    Done,
    /// A job that ends as "failed".
    Failed,
    /// An error for the call.
    Refuse,
}

struct Systemd {
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
    calls: Calls,
}

impl Drop for Systemd {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(t) = self.thread.take() {
            t.join().unwrap();
        }
    }
}

fn systemd(address: &str, answer: Answer) -> Systemd {
    let calls: Calls = Arc::default();
    let stop = Arc::new(AtomicBool::new(false));
    let (ready, started) = mpsc::channel();
    let (address, kept, stopping) = (address.to_owned(), calls.clone(), stop.clone());
    let thread = thread::spawn(move || {
        let bus = Bus::connect(&address).unwrap();
        let interface = Interface::new(MANAGER)
            .method("StartTransientUnit", "ssa(sv)a(sa(sv))", "o")
            .signal("JobRemoved", "uoss");
        let mut jobs = 0;
        let _object = bus
            .export(
                "/org/freedesktop/systemd1",
                vec![interface],
                move |call: &Message, args: Vec<Value>| {
                    kept.lock().unwrap().push(args.clone());
                    if answer == Answer::Refuse {
                        return Err(Error::bus(
                            "org.freedesktop.systemd1.UnitExists",
                            "refused for the test",
                        ));
                    }
                    jobs += 1;
                    let job = format!("/org/freedesktop/systemd1/job/{jobs}");
                    let result = if answer == Answer::Done {
                        "done"
                    } else {
                        "failed"
                    };
                    call.bus().emit_signal(
                        "/org/freedesktop/systemd1",
                        MANAGER,
                        "JobRemoved",
                        &[
                            Value::Uint32(jobs),
                            Value::path(&job),
                            args[0].clone(),
                            Value::str(result),
                        ],
                    )?;
                    Ok(vec![Value::path(job)])
                },
            )
            .unwrap();
        assert!(bus.request_name("org.freedesktop.systemd1", 0).unwrap());
        ready.send(()).unwrap();
        while !stopping.load(Ordering::Relaxed) {
            let mut fds = [bus.poll_fd()];
            poll(
                &mut fds,
                sooner(bus.timeout(), Some(Duration::from_millis(20))),
            )
            .unwrap();
            bus.dispatch().unwrap();
        }
    });
    started.recv_timeout(Duration::from_secs(5)).unwrap();
    Systemd {
        stop,
        thread: Some(thread),
        calls,
    }
}

/// One property of a call to StartTransientUnit.
fn property(call: &[Value], name: &str) -> Option<Value> {
    let Value::Array(_, properties) = &call[2] else {
        panic!("properties")
    };
    properties.iter().find_map(|p| match p {
        Value::Struct(pair) if pair[0] == Value::str(name) => Some(pair[1].unwrap().clone()),
        _ => None,
    })
}

trait Unwrap {
    fn unwrap(&self) -> &Value;
}

impl Unwrap for Value {
    fn unwrap(&self) -> &Value {
        self.unvariant()
    }
}

/// A scratch world: apps in bin, entries under share/applications, and what
/// they wrote in out.
struct World {
    dir: PathBuf,
}

impl World {
    fn new() -> World {
        let dir = scratch("launch");
        fs::create_dir_all(dir.join("bin")).unwrap();
        fs::create_dir_all(dir.join("share/applications")).unwrap();
        World { dir }
    }

    fn script(&self, name: &str, body: &str) {
        let path = self.dir.join("bin").join(name);
        fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
    }

    /// An app that writes its process id, folder and arguments, a line each
    /// in <name>.out.
    fn app(&self, name: &str) {
        let out = self.dir.join(format!("{name}.out"));
        self.script(
            name,
            &format!(
                "echo \"$$\" >> {out}\npwd >> {out}\nfor a in \"$@\"; do echo \"arg:$a\" >> {out}; done",
                out = out.display()
            ),
        );
    }

    fn entry(&self, file: &str, text: &str) -> PathBuf {
        let path = self.dir.join("share/applications").join(file);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, text).unwrap();
        path
    }

    fn out(&self, name: &str) -> Vec<String> {
        for _ in 0..100 {
            if let Ok(text) = fs::read_to_string(self.dir.join(format!("{name}.out"))) {
                return text.lines().map(str::to_owned).collect();
            }
            thread::sleep(Duration::from_millis(20));
        }
        panic!("{name} did not run");
    }

    fn launch(&self, bus: &str, args: &[&str]) -> Output {
        Command::new(BIN)
            .args(args)
            .env(
                "PATH",
                format!("{}:/usr/bin:/bin", self.dir.join("bin").display()),
            )
            .env("DBUS_SESSION_BUS_ADDRESS", bus)
            .env("XDG_DATA_HOME", self.dir.join("share"))
            .env("XDG_DATA_DIRS", self.dir.join("nothing"))
            .env("XDG_CURRENT_DESKTOP", "Hyprland:Nova")
            .env("LANG", "C")
            .env_remove("LANGUAGE")
            .env_remove("LC_ALL")
            .env_remove("LC_MESSAGES")
            .current_dir(&self.dir)
            .output()
            .unwrap()
    }
}

impl Drop for World {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.dir);
    }
}

fn text(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).into_owned()
}

fn is_scope_of(name: &Value, app: &str) -> bool {
    let Value::Str(name) = name else { return false };
    let Some(rest) = name
        .strip_prefix(&format!("app-Hyprland-{app}-"))
        .and_then(|r| r.strip_suffix(".scope"))
    else {
        return false;
    };
    rest.len() == 8 && rest.chars().all(|c| c.is_ascii_hexdigit())
}

#[test]
fn a_command_runs_in_a_scope_as_the_process_that_asked_for_it() {
    let Some(private) = PrivateBus::start() else {
        return;
    };
    let fake = systemd(&private.address, Answer::Done);
    let world = World::new();
    world.app("hello");
    let run = world.launch(&private.address, &["--", "hello", "one", "two words"]);
    assert!(run.status.success(), "{}", text(&run.stderr));
    assert_eq!(text(&run.stderr), "");

    let out = world.out("hello");
    assert_eq!(out[1], world.dir.display().to_string());
    assert_eq!(&out[2..], ["arg:one", "arg:two words"]);

    let calls = fake.calls.lock().unwrap();
    assert_eq!(calls.len(), 1);
    let call = &calls[0];
    assert!(is_scope_of(&call[0], "hello"), "{:?}", call[0]);
    assert_eq!(call[1], Value::str("fail"));
    assert_eq!(
        property(call, "Slice"),
        Some(Value::str("app-graphical.slice"))
    );
    assert_eq!(property(call, "Description"), Some(Value::str("hello")));
    assert_eq!(
        property(call, "CollectMode"),
        Some(Value::str("inactive-or-failed"))
    );
    assert_eq!(property(call, "SourcePath"), None);
    // The app is the process that was put in the scope.
    let pid: u32 = out[0].parse().unwrap();
    assert_eq!(
        property(call, "PIDs"),
        Some(Value::Array("u".into(), vec![Value::Uint32(pid)]))
    );
    assert_eq!(call[3], Value::Array("(sa(sv))".into(), vec![]));
}

#[test]
fn an_entry_runs_by_its_id_with_its_action_and_files() {
    let Some(private) = PrivateBus::start() else {
        return;
    };
    let fake = systemd(&private.address, Answer::Done);
    let world = World::new();
    world.app("viewer");
    let work = world.dir.join("work");
    fs::create_dir(&work).unwrap();
    let path = world.entry(
        "org.example.Viewer.desktop",
        &format!(
            "[Desktop Entry]\nName=Viewer\nGenericName=Picture Viewer\nExec=viewer --show %f\nPath={}\nActions=new;\n\n[Desktop Action new]\nName=New\nExec=viewer --new %i %c\nIcon=eye\n",
            work.display()
        ),
    );

    let run = world.launch(
        &private.address,
        &["--", "org.example.Viewer.desktop", "/tmp/a b"],
    );
    assert!(run.status.success(), "{}", text(&run.stderr));
    let out = world.out("viewer");
    assert_eq!(out[1], work.display().to_string());
    assert_eq!(&out[2..], ["arg:--show", "arg:/tmp/a b"]);
    {
        let calls = fake.calls.lock().unwrap();
        let call = &calls[0];
        assert!(is_scope_of(&call[0], "org.example.Viewer"), "{:?}", call[0]);
        assert_eq!(
            property(call, "Description"),
            Some(Value::str("Viewer - Picture Viewer"))
        );
        assert_eq!(
            property(call, "SourcePath"),
            Some(Value::str(path.to_string_lossy()))
        );
    }

    fs::remove_file(world.dir.join("viewer.out")).unwrap();
    let run = world.launch(&private.address, &["--", "org.example.Viewer.desktop:new"]);
    assert!(run.status.success(), "{}", text(&run.stderr));
    assert_eq!(
        &world.out("viewer")[2..],
        ["arg:--new", "arg:--icon", "arg:eye", "arg:Viewer"]
    );
}

#[test]
fn several_files_for_one_file_entry_start_an_instance_and_a_scope_each() {
    let Some(private) = PrivateBus::start() else {
        return;
    };
    let fake = systemd(&private.address, Answer::Done);
    let world = World::new();
    world.app("viewer");
    world.entry(
        "viewer.desktop",
        "[Desktop Entry]\nName=Viewer\nExec=viewer %u\n",
    );
    let run = world.launch(
        &private.address,
        &["viewer.desktop", "/x", "https://example.org/y"],
    );
    assert!(run.status.success(), "{}", text(&run.stderr));
    for _ in 0..100 {
        if world.dir.join("viewer.out").exists()
            && world
                .out("viewer")
                .iter()
                .filter(|l| l.starts_with("arg:"))
                .count()
                == 2
        {
            break;
        }
        thread::sleep(Duration::from_millis(20));
    }
    let mut args: Vec<String> = world
        .out("viewer")
        .into_iter()
        .filter(|l| l.starts_with("arg:"))
        .collect();
    args.sort();
    assert_eq!(args, ["arg:file:///x", "arg:https://example.org/y"]);
    assert_eq!(fake.calls.lock().unwrap().len(), 2);
}

#[test]
fn a_terminal_entry_runs_through_xdg_terminal_exec() {
    let Some(private) = PrivateBus::start() else {
        return;
    };
    let _fake = systemd(&private.address, Answer::Done);
    let world = World::new();
    world.app("xdg-terminal-exec");
    world.app("htop");
    world.entry(
        "htop.desktop",
        "[Desktop Entry]\nName=Htop\nExec=htop -d 5\nTerminal=true\n",
    );
    let run = world.launch(&private.address, &["--", "htop.desktop"]);
    assert!(run.status.success(), "{}", text(&run.stderr));
    assert_eq!(
        &world.out("xdg-terminal-exec")[2..],
        ["arg:htop", "arg:-d", "arg:5"]
    );
}

#[test]
fn an_app_starts_without_a_scope_when_systemd_cannot_be_reached() {
    let world = World::new();
    world.app("hello");
    let run = world.launch(
        "unix:path=/nonexistent/nova-launch-test",
        &["--", "hello", "x"],
    );
    assert!(run.status.success());
    assert_eq!(&world.out("hello")[2..], ["arg:x"]);
    let said = text(&run.stderr);
    assert!(
        said.contains("session bus") && said.contains("without a scope"),
        "{said}"
    );
}

#[test]
fn an_app_starts_when_systemd_refuses_or_the_job_fails() {
    let Some(private) = PrivateBus::start() else {
        return;
    };
    for (answer, word) in [
        (Answer::Refuse, "refused for the test"),
        (Answer::Failed, "failed"),
    ] {
        let _fake = systemd(&private.address, answer);
        let world = World::new();
        world.app("hello");
        let run = world.launch(&private.address, &["hello"]);
        assert!(run.status.success());
        world.out("hello");
        let said = text(&run.stderr);
        assert!(
            said.contains(word) && said.contains("without a scope"),
            "{said}"
        );
    }
}

/// notify-send in the test's PATH, which writes what it was told.
fn notifier(world: &World) -> PathBuf {
    let told = world.dir.join("told");
    world.script("notify-send", &format!("echo \"$@\" > {}", told.display()));
    told
}

#[test]
fn a_mistake_is_said_on_stderr_and_in_a_notification_and_starts_nothing() {
    let Some(private) = PrivateBus::start() else {
        return;
    };
    let fake = systemd(&private.address, Answer::Done);
    let world = World::new();
    let told = notifier(&world);
    for (args, said) in [
        (
            vec!["--", "no-such-command-here"],
            "Command not found: no-such-command-here",
        ),
        (
            vec!["--", "gone.desktop"],
            "There is no desktop entry gone.desktop",
        ),
        (
            vec!["--", "gone.desktop:action"],
            "There is no desktop entry gone.desktop",
        ),
    ] {
        let _ = fs::remove_file(&told);
        let run = world.launch(&private.address, &args);
        assert_eq!(run.status.code(), Some(1));
        assert!(text(&run.stderr).contains(said), "{}", text(&run.stderr));
        assert!(Path::new(&told).exists(), "no notification for {args:?}");
        assert!(fs::read_to_string(&told).unwrap().contains(said));
    }
    world.entry(
        "hidden.desktop",
        "[Desktop Entry]\nName=H\nExec=sh\nHidden=true\n",
    );
    world.entry("nofiles.desktop", "[Desktop Entry]\nName=N\nExec=sh\n");
    world.entry(
        "missing.desktop",
        "[Desktop Entry]\nName=M\nExec=not-installed-anywhere\n",
    );
    for (args, said) in [
        (vec!["hidden.desktop"], "is hidden"),
        (vec!["nofiles.desktop", "/a"], "does not take files"),
        (vec!["missing.desktop"], "not installed"),
        (vec!["nofiles.desktop:nope"], "no action nope"),
    ] {
        let run = world.launch(&private.address, &args);
        assert_eq!(run.status.code(), Some(1), "{args:?}");
        assert!(text(&run.stderr).contains(said), "{}", text(&run.stderr));
    }
    assert_eq!(fake.calls.lock().unwrap().len(), 0);
}

#[test]
fn nothing_to_run_is_a_usage_error() {
    let world = World::new();
    let run = world.launch("unix:path=/nonexistent", &[]);
    assert_eq!(run.status.code(), Some(2));
    assert!(text(&run.stderr).contains("Usage"));
    let run = world.launch("unix:path=/nonexistent", &["--help"]);
    assert!(run.status.success() && text(&run.stdout).contains("Usage"));
}

/// How long a launch takes: `cargo test --release -p nova-launch -- --ignored --nocapture`.
#[test]
#[ignore]
fn timing_of_a_hundred_launches() {
    let Some(private) = PrivateBus::start() else {
        return;
    };
    let _fake = systemd(&private.address, Answer::Done);
    let world = World::new();
    let mut times = Vec::new();
    for _ in 0..100 {
        let begun = std::time::Instant::now();
        let run = world.launch(&private.address, &["--", "true"]);
        times.push(begun.elapsed());
        assert!(run.status.success());
    }
    times.sort();
    println!(
        "100 launches of /bin/true: median {:?}, mean {:?}, slowest {:?}",
        times[50],
        times.iter().sum::<Duration>() / 100,
        times[99]
    );
}
