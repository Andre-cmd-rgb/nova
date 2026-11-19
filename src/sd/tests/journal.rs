//! nova-sd's journal against journal files of the test's own, written by
//! systemd-journal-remote: matches, the end, and entries followed as they come.

use std::path::Path;
use std::process::Command;
use std::time::{Duration, Instant};

use nova_sd::poll::{poll, sooner};
use nova_sd::testing::scratch;
use nova_sd::Journal;

const REMOTE: &str = "/usr/lib/systemd/systemd-journal-remote";

/// Writes entries, each a list of fields, into <dir>'s journal file.
fn write(dir: &Path, at: u64, entries: &[&[(&str, &str)]]) {
    let mut export = String::new();
    for (i, fields) in entries.iter().enumerate() {
        let n = at + i as u64;
        export += &format!(
            "__REALTIME_TIMESTAMP={}\n__MONOTONIC_TIMESTAMP={}\n_BOOT_ID=0123456789abcdef0123456789abcdef\n",
            1_700_000_000_000_000 + n * 1000,
            1000 + n
        );
        for (k, v) in *fields {
            export += &format!("{k}={v}\n");
        }
        export += "\n";
    }
    let file = dir.join("entries.export");
    std::fs::write(&file, export).unwrap();
    let status = Command::new(REMOTE)
        .arg(format!("--output={}/test.journal", dir.display()))
        .arg(&file)
        .stderr(std::process::Stdio::null())
        .status()
        .unwrap();
    assert!(status.success());
}

const CRASH: &str = "fc2e22bc6ee647b6b90729ab34a250b1";

#[test]
fn matched_entries_from_the_end_on_as_they_are_written() {
    if !Path::new(REMOTE).exists() {
        eprintln!("skipped: no systemd-journal-remote to write a journal with");
        return;
    }
    let dir = scratch("journal");
    write(
        &dir,
        0,
        &[
            &[
                ("MESSAGE", "an old crash"),
                ("MESSAGE_ID", CRASH),
                ("COREDUMP_UID", "1000"),
                ("COREDUMP_PID", "1"),
            ],
            &[("MESSAGE", "something else")],
        ],
    );
    let mut journal = Journal::open_directory(&dir).unwrap();
    journal.add_match("MESSAGE_ID", CRASH).unwrap();
    journal.add_match("COREDUMP_UID", "1000").unwrap();

    // From the start, the one that matches.
    journal.seek_head().unwrap();
    assert!(journal.next_entry().unwrap());
    assert_eq!(journal.field("COREDUMP_PID").unwrap().as_deref(), Some("1"));
    assert_eq!(journal.field("NOTHING").unwrap(), None);
    assert!(!journal.next_entry().unwrap());

    // From the end, only what comes.
    journal.seek_end().unwrap();
    assert!(!journal.next_entry().unwrap());
    let mut fds = [journal.poll_fd().unwrap()];
    write(
        &dir,
        2,
        &[
            &[
                ("MESSAGE", "another user's"),
                ("MESSAGE_ID", CRASH),
                ("COREDUMP_UID", "1001"),
                ("COREDUMP_PID", "2"),
            ],
            &[
                ("MESSAGE", "a new crash"),
                ("MESSAGE_ID", CRASH),
                ("COREDUMP_UID", "1000"),
                ("COREDUMP_PID", "3"),
            ],
        ],
    );
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut found = Vec::new();
    while found.is_empty() {
        assert!(Instant::now() < deadline, "the new entry never came");
        poll(
            &mut fds,
            sooner(journal.timeout(), Some(Duration::from_millis(100))),
        )
        .unwrap();
        journal.process().unwrap();
        while journal.next_entry().unwrap() {
            found.push(journal.field("COREDUMP_PID").unwrap().unwrap());
        }
    }
    assert_eq!(found, vec!["3"]);
    assert!(journal.realtime_usec().unwrap() > 1_700_000_000_000_000);
    let _ = std::fs::remove_dir_all(&dir);
}
