//! nova-memory-pressure as its unit runs it, on a fixture: what a start finds
//! decides whether it stays. The waking itself needs the kernel's pressure
//! file (a plain file never wakes a poll for POLLPRI); the install test's
//! machine and the pressure runs in docs/ARCHITECTURE.md cover that.

use std::fs;
use std::io::Read;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::thread::sleep;
use std::time::{Duration, Instant};

struct Fixture {
    root: PathBuf,
}

impl Fixture {
    /// A /proc and a /run with this factor in force and this one written at boot.
    fn new(name: &str, in_force: &str, written: &str) -> Fixture {
        let root = std::env::temp_dir().join(format!(
            "nova-memory-pressure-{}-{name}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(root.join("proc/sys/vm")).unwrap();
        fs::create_dir_all(root.join("proc/pressure")).unwrap();
        fs::create_dir_all(root.join("run/sysctl.d")).unwrap();
        fs::write(
            root.join("proc/sys/vm/watermark_scale_factor"),
            format!("{in_force}\n"),
        )
        .unwrap();
        fs::write(root.join("proc/pressure/memory"), "").unwrap();
        fs::write(
            root.join("run/sysctl.d/90-nova-memory-reserve.conf"),
            format!("# for the test\nvm.watermark_scale_factor = {written}\n"),
        )
        .unwrap();
        Fixture { root }
    }

    fn mark(&self) -> PathBuf {
        self.root.join("run/nova-memory-pressure/managed")
    }

    fn in_force(&self) -> String {
        fs::read_to_string(self.root.join("proc/sys/vm/watermark_scale_factor"))
            .unwrap()
            .trim()
            .to_string()
    }

    fn start(&self) -> Child {
        Command::new(env!("CARGO_BIN_EXE_nova-memory-pressure"))
            .env("NOVA_PROC", self.root.join("proc"))
            .env("NOVA_RUN", self.root.join("run"))
            .stdin(Stdio::null())
            // Never the test runner's own output: a child left behind by a
            // failed test would keep it open.
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap()
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

/// True once the program has ended by itself, within two seconds.
fn ends(child: &mut Child) -> bool {
    let deadline = Instant::now() + Duration::from_secs(2);
    while Instant::now() < deadline {
        if let Some(status) = child.try_wait().unwrap() {
            assert!(status.success(), "ended with {status}");
            return true;
        }
        sleep(Duration::from_millis(10));
    }
    false
}

fn stop(mut child: Child) -> String {
    child.kill().unwrap();
    child.wait().unwrap();
    let mut said = String::new();
    child
        .stderr
        .take()
        .unwrap()
        .read_to_string(&mut said)
        .unwrap();
    said
}

#[test]
fn it_stays_where_the_boot_value_is_lean_asks_for_its_trigger_and_leaves_no_mark() {
    let fixture = Fixture::new("lean", "31", "31");
    // One left by an earlier release, which marked the lean value too.
    fs::create_dir_all(fixture.mark().parent().unwrap()).unwrap();
    fs::write(fixture.mark(), "").unwrap();
    let mut child = fixture.start();
    let trigger = fixture.root.join("proc/pressure/memory");
    let deadline = Instant::now() + Duration::from_secs(2);
    while fs::read(&trigger).unwrap().is_empty() && Instant::now() < deadline {
        assert!(child.try_wait().unwrap().is_none(), "the program ended");
        sleep(Duration::from_millis(10));
    }
    assert_eq!(fs::read(&trigger).unwrap(), b"some 100000 1000000\0");
    // Asleep: still there, nothing written, and no mark: the mark says a
    // 125 is its own raise, and there is none. Stopped before anything is
    // judged, so that a failure leaves no program behind.
    sleep(Duration::from_millis(200));
    let running = child.try_wait().unwrap().is_none();
    let marked = fixture.mark().exists();
    let said = stop(child);
    assert!(running, "{said}");
    assert!(!marked, "the lean value is marked");
    assert_eq!(said, "");
    assert_eq!(fixture.in_force(), "31");
}

#[test]
fn it_ends_at_once_where_the_boot_value_is_the_full_one() {
    let fixture = Fixture::new("full", "125", "125");
    let mut child = fixture.start();
    assert!(ends(&mut child));
    assert!(!fixture.mark().exists());
    assert_eq!(fixture.in_force(), "125");
}

#[test]
fn it_ends_at_once_where_the_value_in_force_is_an_administrators() {
    for own in ["200", "125", "10"] {
        let fixture = Fixture::new(&format!("own-{own}"), own, "31");
        let mut child = fixture.start();
        assert!(ends(&mut child), "{own}");
        assert!(!fixture.mark().exists());
        assert_eq!(fixture.in_force(), own);
    }
}

#[test]
fn started_again_after_its_own_raise_it_stays_and_says_so() {
    let fixture = Fixture::new("raised", "125", "31");
    fs::create_dir_all(fixture.mark().parent().unwrap()).unwrap();
    fs::write(fixture.mark(), "").unwrap();
    let mut child = fixture.start();
    sleep(Duration::from_millis(300));
    assert!(child.try_wait().unwrap().is_none());
    let said = stop(child);
    assert!(
        said.contains("taken up again with the full reserve in force: 31 after five minutes"),
        "{said}"
    );
    // The five minutes have not passed: still the full one.
    assert_eq!(fixture.in_force(), "125");
}
