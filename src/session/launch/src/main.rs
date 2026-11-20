//! nova-launch: starts an app the way Nova wants every app started, as a
//! systemd scope of its own in app-graphical.slice.
//!
//!     nova-launch [--] <command> [arguments]
//!     nova-launch [--] <id>.desktop[:action] [files or addresses]
//!
//! A scope per app is what lets systemd-oomd end the one app that ran
//! memory short, and `systemctl --user status` say what runs and where it
//! came from. systemd-run --scope does this by making the unit with its own
//! process in it and then running the app in place; so does this, directly
//! over the session bus and without a daemon in between, so that a launch is
//! one small process that becomes the app.
//!
//! If systemd cannot be reached the app starts anyway, outside a scope, and
//! the reason goes to stderr: a launch is never lost for want of a scope.
//! What a person can get wrong (no such entry, no such command) is said on
//! stderr and, when that is not a terminal, in a notification.

mod desktop;
mod unit;

use std::env;
use std::ffi::OsString;
use std::io::IsTerminal;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{self, Command};

use desktop::Entry;

const USAGE: &str = "Usage: nova-launch [--] <command> [arguments...]
       nova-launch [--] <id>.desktop[:action] [files or addresses...]

Starts the command, or the desktop entry with that id, in a systemd scope of
its own in app-graphical.slice.";

extern "C" {
    fn fork() -> i32;
    fn waitpid(pid: i32, status: *mut i32, options: i32) -> i32;
    fn _exit(code: i32) -> !;
}

/// Says what went wrong, and ends: on stderr, and in a notification when
/// stderr is not a terminal (a launch from a key or the menu has none).
fn fail(message: &str) -> ! {
    report(message);
    process::exit(1);
}

/// As `fail`, for a process that goes on or ends in its own way.
fn report(message: &str) {
    eprintln!("nova-launch: {message}");
    if !std::io::stderr().is_terminal() {
        let _ = Command::new("notify-send")
            .args([
                "-u",
                "critical",
                "-i",
                "error",
                "-a",
                "nova-launch",
                "App failure",
            ])
            .arg(message)
            .status();
    }
}

/// What to start: each command (more than one when an entry takes a single
/// file and several came), what the scope is called and says, and where to run.
struct Plan {
    commands: Vec<Vec<OsString>>,
    app: String,
    description: String,
    source_path: Option<String>,
    workdir: Option<PathBuf>,
}

/// <word> is meant as a desktop entry: an id, with an action maybe, or a path.
fn entry_word(word: &str) -> Option<(&str, Option<&str>)> {
    if let Some(id) = word.strip_suffix(".desktop") {
        return (!id.is_empty()).then_some((word, None));
    }
    let (id, action) = word.split_once(".desktop:")?;
    let end = id.len() + ".desktop".len();
    Some((&word[..end], Some(action).filter(|a| !a.is_empty())))
}

fn id_is_valid(id: &str) -> bool {
    id.chars()
        .all(|c| c.is_ascii_alphanumeric() || "_.+-".contains(c))
}

/// The plan for the entry named by <word>, with <files> for its codes.
fn entry_plan(word: &str, files: &[OsString]) -> Result<Plan, String> {
    let (id_or_path, action) = entry_word(word).expect("an entry word");
    if let Some(action) = action {
        if !action
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-')
        {
            return Err(format!("{action} is not the name of a desktop action"));
        }
    }
    let dirs = desktop::application_dirs();
    let as_path = if id_or_path.contains('/') {
        Some(expand_home(id_or_path))
    } else if !id_is_valid(id_or_path) && Path::new(id_or_path).is_file() {
        Some(PathBuf::from("./").join(id_or_path))
    } else {
        None
    };
    let (path, id) = match as_path {
        Some(path) => {
            if !path.is_file() {
                return Err(format!("There is no desktop entry file {}", path.display()));
            }
            let absolute = env::current_dir().map_or(path.clone(), |d| d.join(&path));
            let id = desktop::id_of(&dirs, &absolute);
            (path, id)
        }
        None => {
            if !id_is_valid(id_or_path) {
                return Err(format!("{id_or_path} is not a desktop entry id"));
            }
            let path = desktop::find(&dirs, id_or_path)
                .ok_or_else(|| format!("There is no desktop entry {id_or_path}"))?;
            (path, id_or_path.to_owned())
        }
    };
    let entry = Entry::read(&path)?;
    // Where the app runs: its Path, and what is relative in the entry is
    // relative to that.
    let workdir = entry.working_directory();
    if let Some(dir) = &workdir {
        if !dir.is_dir() {
            return Err(format!(
                "The desktop entry {id} wants to run in {}, which is not a folder",
                dir.display()
            ));
        }
    }
    entry.check_runnable(workdir.as_deref())?;
    let exec = entry.exec(action)?;
    if desktop::which_in(&exec[0], workdir.as_deref()).is_none() {
        return Err(format!(
            "The desktop entry {id} starts {}, which is not installed",
            exec[0]
        ));
    }
    let absolute = env::current_dir().map_or(path.clone(), |d| d.join(&path));
    let source = absolute.to_string_lossy().into_owned();
    let name = entry.name();
    let icon = entry.icon(action);
    let fields = desktop::Fields {
        name: &name,
        path: &source,
        icon: icon.as_deref(),
    };
    let mut commands =
        desktop::commands(&exec, files, &fields).map_err(|e| format!("{e}: {id}"))?;
    if entry.terminal() {
        for command in &mut commands {
            command.insert(0, "xdg-terminal-exec".into());
        }
    }
    Ok(Plan {
        commands,
        app: id.strip_suffix(".desktop").unwrap_or(&id).to_owned(),
        description: entry.description(),
        source_path: Some(source),
        workdir,
    })
}

fn expand_home(path: &str) -> PathBuf {
    match (path.strip_prefix("~/"), env::var_os("HOME")) {
        (Some(rest), Some(home)) => Path::new(&home).join(rest),
        _ => PathBuf::from(path),
    }
}

/// The plan for a command as it is.
fn command_plan(command: Vec<OsString>) -> Plan {
    let name = Path::new(&command[0])
        .file_name()
        .map_or_else(|| command[0].clone(), OsString::from)
        .to_string_lossy()
        .into_owned();
    Plan {
        commands: vec![command],
        app: name.clone(),
        description: name,
        source_path: None,
        workdir: None,
    }
}

/// Puts this process in a scope for the app, then becomes the app. Only
/// returns an error, for the app that could not be started.
fn run(plan: &Plan, command: &[OsString]) -> std::io::Error {
    let scope = unit::Scope {
        name: unit::scope_name(
            &env::var("XDG_CURRENT_DESKTOP").unwrap_or_default(),
            &plan.app,
            &unit::random_hex(),
        ),
        description: plan.description.clone(),
        source_path: plan.source_path.clone(),
    };
    if let Err(why) = unit::enter(&scope) {
        eprintln!(
            "nova-launch: {why}; starting {} without a scope of its own",
            plan.app
        );
    }
    let mut start = Command::new(&command[0]);
    start.args(&command[1..]);
    if let Some(dir) = &plan.workdir {
        start.current_dir(dir);
    }
    start.exec()
}

/// Starts one of several instances on its own: in a process that is not this
/// one's child once it is running, so that nobody has to wait for it.
fn detached(plan: &Plan, command: &[OsString]) {
    // SAFETY: this process has one thread and no locks held; both children
    // only run this program's own code and end with exec or _exit.
    unsafe {
        let child = fork();
        if child < 0 {
            fail("could not start another instance: fork failed");
        }
        if child == 0 {
            if fork() == 0 {
                let error = run(plan, command);
                report(&format!("could not start {}: {error}", plan.app));
            }
            _exit(0);
        }
        let mut status = 0;
        waitpid(child, &mut status, 0);
    }
}

fn main() {
    let mut args: Vec<OsString> = env::args_os().skip(1).collect();
    if matches!(args.first().and_then(|a| a.to_str()), Some("-h" | "--help")) {
        println!("{USAGE}");
        return;
    }
    // After -- the first word is the program, whatever it starts with.
    let explicit = args.first().is_some_and(|a| a == "--");
    if explicit {
        args.remove(0);
    }
    let Some(first) = args.first() else {
        eprintln!("{USAGE}");
        process::exit(2);
    };
    if !explicit && first.as_bytes().first() == Some(&b'-') {
        eprintln!(
            "nova-launch: {} is not a command; put -- before it\n{USAGE}",
            first.to_string_lossy()
        );
        process::exit(2);
    }

    let plan = match first.to_str().filter(|w| entry_word(w).is_some()) {
        Some(word) => entry_plan(word, &args[1..]).unwrap_or_else(|why| fail(&why)),
        None => {
            if desktop::which(&first.to_string_lossy()).is_none() {
                fail(&format!("Command not found: {}", first.to_string_lossy()));
            }
            command_plan(args)
        }
    };
    for command in &plan.commands {
        if desktop::which_in(&command[0].to_string_lossy(), plan.workdir.as_deref()).is_none() {
            fail(&format!(
                "Command not found: {}",
                command[0].to_string_lossy()
            ));
        }
    }

    // All but the last start on their own; this process becomes the last.
    let (last, others) = plan.commands.split_last().expect("a command");
    for command in others {
        detached(&plan, command);
    }
    let error = run(&plan, last);
    fail(&format!("could not start {}: {error}", plan.app));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_word_is_an_entry_by_its_ending() {
        assert_eq!(entry_word("a.b.desktop"), Some(("a.b.desktop", None)));
        assert_eq!(
            entry_word("a.desktop:new"),
            Some(("a.desktop", Some("new")))
        );
        assert_eq!(entry_word("a.desktop:"), Some(("a.desktop", None)));
        assert_eq!(
            entry_word("/x/y.desktop:new"),
            Some(("/x/y.desktop", Some("new")))
        );
        assert_eq!(entry_word("firefox"), None);
        assert_eq!(entry_word(".desktop"), None);
    }
}
