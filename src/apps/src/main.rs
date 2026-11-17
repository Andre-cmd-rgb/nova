//! nova-apps-catalog: the App Store's catalog, made from Flathub's, Arch's
//! and Nova's own, and kept in the cache until one of them changes.

mod appstream;
mod catalog;
mod json;
mod sources;
mod xml;

use std::fs;
use std::io::Write;
use std::process::ExitCode;
use std::time::{SystemTime, UNIX_EPOCH};

const USAGE: &str = "\
Usage: nova-apps-catalog [--force]

Makes the App Store's catalog, if what it is made from changed since it was
last made (--force: in any case), and prints the file it is in:
$XDG_CACHE_HOME/nova/apps/catalog.json.
";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let force = match args
        .iter()
        .map(String::as_str)
        .collect::<Vec<_>>()
        .as_slice()
    {
        [] => false,
        ["--force"] => true,
        ["-h" | "--help"] => {
            print!("{USAGE}");
            return ExitCode::SUCCESS;
        }
        _ => {
            eprint!("{USAGE}");
            return ExitCode::from(2);
        }
    };
    match run(force) {
        Ok(path) => {
            println!("{path}");
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("nova-apps-catalog: {e}");
            ExitCode::FAILURE
        }
    }
}

/// Writes a file whole or not at all: a reader sees the old one or the new.
fn replace(path: &std::path::Path, text: &str) -> Result<(), String> {
    let part = path.with_extension(format!("part.{}", std::process::id()));
    let mut f = fs::File::create(&part).map_err(|e| format!("{}: {e}", part.display()))?;
    f.write_all(text.as_bytes())
        .map_err(|e| format!("{}: {e}", part.display()))?;
    fs::rename(&part, path).map_err(|e| format!("{}: {e}", path.display()))
}

fn run(force: bool) -> Result<String, String> {
    let dir = sources::cache_dir();
    fs::create_dir_all(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    let path = dir.join("catalog.json");
    let stamp_path = dir.join("catalog.stamp");
    let stamp = sources::stamp();
    if !force && path.is_file() && fs::read_to_string(&stamp_path).is_ok_and(|s| s == stamp) {
        return Ok(path.display().to_string());
    }
    let inputs = sources::gather()?;
    let apps = catalog::build(&inputs);
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    replace(&path, &catalog::write(&apps, &inputs, now))?;
    replace(&stamp_path, &stamp)?;
    Ok(path.display().to_string())
}
