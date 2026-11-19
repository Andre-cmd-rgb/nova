//! A bus of a test's own: a dbus-daemon on a socket in a fresh folder, which
//! nothing else is on, gone with the test. Tests never use the user's session
//! bus or the system bus.

use std::io::{BufRead, BufReader};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicU32, Ordering};

pub struct PrivateBus {
    pub address: String,
    pub dir: PathBuf,
    daemon: Child,
}

static NEXT: AtomicU32 = AtomicU32::new(0);

/// A folder of the test's own under the temporary one.
pub fn scratch(what: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "nova-sd-{what}-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("a scratch folder");
    dir
}

impl PrivateBus {
    /// A new bus; none where dbus-daemon is not installed, for the test to skip.
    pub fn start() -> Option<PrivateBus> {
        let dir = scratch("bus");
        let config = dir.join("bus.conf");
        std::fs::write(
            &config,
            format!(
                r#"<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>unix:path={}/socket</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow eavesdrop="true"/>
    <allow own="*"/>
  </policy>
</busconfig>
"#,
                dir.display()
            ),
        )
        .ok()?;
        let mut daemon = match Command::new("dbus-daemon")
            .arg(format!("--config-file={}", config.display()))
            .args(["--nofork", "--print-address=1"])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
        {
            Ok(daemon) => daemon,
            Err(_) => {
                eprintln!("skipped: no dbus-daemon to run a private bus with");
                return None;
            }
        };
        let mut line = String::new();
        BufReader::new(daemon.stdout.take()?)
            .read_line(&mut line)
            .ok()?;
        Some(PrivateBus {
            address: line.trim().to_owned(),
            dir,
            daemon,
        })
    }
}

impl Drop for PrivateBus {
    fn drop(&mut self) {
        let _ = self.daemon.kill();
        let _ = self.daemon.wait();
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}
