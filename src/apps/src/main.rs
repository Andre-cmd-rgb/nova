//! nova-apps-catalog: the App Center's catalog, made from Flathub's, Arch's
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
Usage: nova-apps-catalog [--force] [--list]

Makes the App Center's catalog, if what it is made from changed since it was
last made (--force: in any case), and prints the file it is in:
$XDG_CACHE_HOME/nova/apps/catalog.json.

--list prints the App Center window's file instead: list.json, each app in
brief with the name of its page in pages/, which has the rest of it.
";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let (force, list) = match args
        .iter()
        .map(String::as_str)
        .collect::<Vec<_>>()
        .as_slice()
    {
        [] => (false, false),
        ["--force"] => (true, false),
        ["--list"] => (false, true),
        ["--force", "--list"] | ["--list", "--force"] => (true, true),
        ["-h" | "--help"] => {
            print!("{USAGE}");
            return ExitCode::SUCCESS;
        }
        _ => {
            eprint!("{USAGE}");
            return ExitCode::from(2);
        }
    };
    match run(force, list) {
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

/// Puts a folder in place of another, whole: it is written beside it and
/// renamed, and the old one removed after, so a reader finds the old set of
/// files or the new.
fn replace_dir(dir: &std::path::Path, files: &[(String, String)]) -> Result<(), String> {
    let pid = std::process::id();
    let new = dir.with_extension(format!("new.{pid}"));
    let old = dir.with_extension(format!("old.{pid}"));
    let _ = fs::remove_dir_all(&new);
    fs::create_dir_all(&new).map_err(|e| format!("{}: {e}", new.display()))?;
    for (name, text) in files {
        let file = new.join(name);
        fs::write(&file, text).map_err(|e| format!("{}: {e}", file.display()))?;
    }
    let _ = fs::remove_dir_all(&old);
    let had = dir.exists();
    if had {
        fs::rename(dir, &old).map_err(|e| format!("{}: {e}", dir.display()))?;
    }
    if let Err(e) = fs::rename(&new, dir) {
        if had {
            let _ = fs::rename(&old, dir);
        }
        return Err(format!("{}: {e}", dir.display()));
    }
    let _ = fs::remove_dir_all(&old);
    Ok(())
}

/// Whether the files in the cache are the ones for these inputs: the
/// catalog, the list and the folder of pages are all there, and were made
/// from what the stamp says. An older version made the catalog and the stamp
/// only.
fn made(dir: &std::path::Path, stamp: &str) -> bool {
    dir.join("catalog.json").is_file()
        && dir.join("list.json").is_file()
        && dir.join("pages").is_dir()
        && fs::read_to_string(dir.join("catalog.stamp")).is_ok_and(|s| s == stamp)
}

fn run(force: bool, list: bool) -> Result<String, String> {
    let dir = sources::cache_dir();
    fs::create_dir_all(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    let path = dir.join(if list { "list.json" } else { "catalog.json" });
    let stamp_path = dir.join("catalog.stamp");
    let stamp = sources::stamp();
    if !force && made(&dir, &stamp) {
        return Ok(path.display().to_string());
    }
    let inputs = sources::gather()?;
    let apps = catalog::build(&inputs);
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let pages = dir.join("pages");
    let files: Vec<(String, String)> = apps
        .iter()
        .map(|a| {
            (
                catalog::page_name(&a.meta.id),
                catalog::write_page(a, &inputs),
            )
        })
        .collect();
    replace_dir(&pages, &files)?;
    replace(
        &dir.join("list.json"),
        &catalog::write_list(&apps, &inputs, now, &pages.display().to_string()),
    )?;
    replace(
        &dir.join("catalog.json"),
        &catalog::write(&apps, &inputs, now),
    )?;
    replace(&stamp_path, &stamp)?;
    Ok(path.display().to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("nova-apps-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn the_pages_are_replaced_whole() {
        let dir = scratch("pages");
        let pages = dir.join("pages");
        let one = |name: &str| vec![(name.to_string(), "{}".to_string())];
        replace_dir(&pages, &one("a.json")).unwrap();
        assert!(pages.join("a.json").is_file());
        replace_dir(&pages, &one("b.json")).unwrap();
        assert!(!pages.join("a.json").exists());
        assert!(pages.join("b.json").is_file());
        // Nothing of the writing is left beside it.
        let left: Vec<_> = fs::read_dir(&dir).unwrap().flatten().collect();
        assert_eq!(left.len(), 1);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_catalog_is_made_when_any_of_its_files_is_missing_or_the_stamp_differs() {
        let dir = scratch("stamp");
        assert!(!made(&dir, "s"));
        // What an older version left: the catalog and the stamp.
        fs::write(dir.join("catalog.json"), "{}").unwrap();
        fs::write(dir.join("catalog.stamp"), "s").unwrap();
        assert!(!made(&dir, "s"));
        fs::write(dir.join("list.json"), "{}").unwrap();
        assert!(!made(&dir, "s"));
        fs::create_dir(dir.join("pages")).unwrap();
        assert!(made(&dir, "s"));
        assert!(!made(&dir, "t"));
        fs::remove_file(dir.join("list.json")).unwrap();
        assert!(!made(&dir, "s"));
        let _ = fs::remove_dir_all(&dir);
    }
}
