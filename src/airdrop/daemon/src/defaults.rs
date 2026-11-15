//! What the daemon goes by when it is told nothing: this computer's name as
//! senders see it, the folder what they send lands in, the country whose
//! radio rules the card is under.

use std::path::{Path, PathBuf};

/// The value of `KEY=value` or `KEY="value"` in a file of such lines.
fn value<'a>(text: &'a str, key: &str) -> Option<&'a str> {
    text.lines()
        .filter_map(|line| line.trim().strip_prefix(key)?.strip_prefix('='))
        .map(|value| value.trim().trim_matches('"'))
        .find(|value| !value.is_empty())
}

/// The computer's name for people if it has one (machine-info), else its host name; and a computer
/// still called what the installer calls one is called as Nova writes itself.
fn named(machine_info: &str, hostname: &str) -> String {
    let name = value(machine_info, "PRETTY_HOSTNAME")
        .unwrap_or(hostname.trim())
        .chars()
        .filter(|c| !c.is_control())
        .take(60)
        .collect::<String>();
    match name.as_str() {
        "" | "nova" | "localhost" => "Nova".into(),
        _ => name,
    }
}

pub fn name() -> String {
    let read = |path: &str| std::fs::read_to_string(path).unwrap_or_default();
    named(
        &read("/etc/machine-info"),
        &read("/proc/sys/kernel/hostname"),
    )
}

/// The downloads folder as user-dirs.dirs names it (it is "Scaricati" in Italian), else Downloads.
fn downloads(user_dirs: &str, home: &Path) -> PathBuf {
    match value(user_dirs, "XDG_DOWNLOAD_DIR") {
        Some(folder) if folder.starts_with("$HOME/") && folder.len() > 6 => home.join(&folder[6..]),
        Some(folder) if folder.starts_with('/') => PathBuf::from(folder),
        _ => home.join("Downloads"),
    }
}

pub fn folder(home: &Path) -> PathBuf {
    let config = match std::env::var_os("XDG_CONFIG_HOME") {
        Some(folder) if !folder.is_empty() => PathBuf::from(folder),
        _ => home.join(".config"),
    };
    downloads(
        &std::fs::read_to_string(config.join("user-dirs.dirs")).unwrap_or_default(),
        home,
    )
}

/// Two capital letters, or what AWDL says for "nowhere in particular".
pub fn country(text: &str) -> [u8; 2] {
    match text.trim().as_bytes() {
        [a, b] if a.is_ascii_uppercase() && b.is_ascii_uppercase() => [*a, *b],
        _ => *b"XZ",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_name_is_the_one_people_gave_the_computer() {
        assert_eq!(
            named(
                "PRETTY_HOSTNAME=\"Zoë's laptop\"\nCHASSIS=laptop\n",
                "zoe-p1\n"
            ),
            "Zoë's laptop"
        );
        assert_eq!(named("CHASSIS=laptop\n", "zoe-p1\n"), "zoe-p1");
        assert_eq!(named("", "nova\n"), "Nova");
        assert_eq!(named("", ""), "Nova");
    }

    #[test]
    fn the_folder_is_the_one_the_desktop_calls_downloads() {
        let home = Path::new("/home/zoe");
        let dirs = "# made by xdg-user-dirs\nXDG_DESKTOP_DIR=\"$HOME/Scrivania\"\nXDG_DOWNLOAD_DIR=\"$HOME/Scaricati\"\n";
        assert_eq!(downloads(dirs, home), Path::new("/home/zoe/Scaricati"));
        assert_eq!(
            downloads("XDG_DOWNLOAD_DIR=\"/data/in\"\n", home),
            Path::new("/data/in")
        );
        // Downloads set to the home folder itself, or to nothing that can be read: the usual place.
        assert_eq!(
            downloads("XDG_DOWNLOAD_DIR=\"$HOME/\"\n", home),
            Path::new("/home/zoe/Downloads")
        );
        assert_eq!(
            downloads("XDG_DOWNLOAD_DIR=\"relative\"\n", home),
            Path::new("/home/zoe/Downloads")
        );
        assert_eq!(downloads("", home), Path::new("/home/zoe/Downloads"));
    }

    #[test]
    fn the_country_is_two_capitals_or_nowhere() {
        assert_eq!(
            (country("IT\n"), country("00"), country(""), country("ita")),
            (*b"IT", *b"XZ", *b"XZ", *b"XZ")
        );
    }
}
