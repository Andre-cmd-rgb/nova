//! Desktop entries: finding one by its id, reading it, and turning its Exec
//! line into the command to run, as the Desktop Entry Specification says.

use std::env;
use std::ffi::{OsStr, OsString};
use std::fs;
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::path::{Path, PathBuf};

/// The folders entries are looked for in, first the user's: $XDG_DATA_HOME
/// and then each of $XDG_DATA_DIRS, each with "applications" in it.
pub fn application_dirs() -> Vec<PathBuf> {
    let home = env::var("XDG_DATA_HOME")
        .ok()
        .filter(|d| !d.is_empty())
        .map(PathBuf::from)
        .or_else(|| env::var_os("HOME").map(|h| Path::new(&h).join(".local/share")));
    let dirs = env::var("XDG_DATA_DIRS")
        .ok()
        .filter(|d| !d.is_empty())
        .unwrap_or_else(|| "/usr/local/share:/usr/share".into());
    home.into_iter()
        .chain(dirs.split(':').filter(|d| !d.is_empty()).map(PathBuf::from))
        .map(|d| d.join("applications"))
        .collect()
}

/// The file of entry <id> (org.example.App.desktop) under <dir>. A "-" in an
/// id may be a "/": org.example-App.desktop is org/example-App.desktop or
/// org-example/App.desktop too.
fn find_in(dir: &Path, id: &str) -> Option<PathBuf> {
    let direct = dir.join(id);
    if direct.is_file() {
        return Some(direct);
    }
    for (at, _) in id.match_indices('-') {
        let folder = dir.join(&id[..at]);
        if folder.is_dir() {
            if let Some(found) = find_in(&folder, &id[at + 1..]) {
                return Some(found);
            }
        }
    }
    None
}

/// The first file of entry <id> in <dirs>.
pub fn find(dirs: &[PathBuf], id: &str) -> Option<PathBuf> {
    dirs.iter().find_map(|dir| find_in(dir, id))
}

/// The id a file in one of <dirs> has: its path under the folder, with "/"
/// as "-"; or its own name, for a file elsewhere.
pub fn id_of(dirs: &[PathBuf], path: &Path) -> String {
    for dir in dirs {
        if let Ok(rest) = path.strip_prefix(dir) {
            return rest.to_string_lossy().replace('/', "-");
        }
    }
    path.file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default()
}

/// A desktop entry file, read: its groups, each with its keys, in order.
pub struct Entry {
    pub path: PathBuf,
    groups: Vec<(String, Vec<(String, String)>)>,
    /// Languages to look for a name in, most wanted first.
    languages: Vec<String>,
}

/// The names a locale answers to, longest first: de_AT.UTF-8@euro is
/// de_AT@euro, de_AT, de@euro and de.
fn locale_keys(locale: &str) -> Vec<String> {
    let (rest, modifier) = match locale.split_once('@') {
        Some((rest, modifier)) => (rest, Some(modifier)),
        None => (locale, None),
    };
    let rest = rest.split('.').next().unwrap_or("");
    let (lang, country) = match rest.split_once('_') {
        Some((lang, country)) => (lang, Some(country)),
        None => (rest, None),
    };
    let mut keys = Vec::new();
    if lang.is_empty() || lang == "C" || lang == "POSIX" {
        return keys;
    }
    if let (Some(country), Some(modifier)) = (country, modifier) {
        keys.push(format!("{lang}_{country}@{modifier}"));
    }
    if let Some(country) = country {
        keys.push(format!("{lang}_{country}"));
    }
    if let Some(modifier) = modifier {
        keys.push(format!("{lang}@{modifier}"));
    }
    keys.push(lang.to_owned());
    keys
}

/// The languages the environment asks for, as the gettext family does:
/// $LANGUAGE (when the locale is not C), else $LC_ALL, $LC_MESSAGES, $LANG.
fn environment_languages() -> Vec<String> {
    let var = |name: &str| env::var(name).ok().filter(|v| !v.is_empty());
    let locale = var("LC_ALL")
        .or_else(|| var("LC_MESSAGES"))
        .or_else(|| var("LANG"))
        .unwrap_or_default();
    let mut keys = Vec::new();
    if !locale_keys(&locale).is_empty() {
        if let Some(list) = var("LANGUAGE") {
            for one in list.split(':') {
                keys.extend(locale_keys(one));
            }
        }
    }
    keys.extend(locale_keys(&locale));
    keys
}

impl Entry {
    pub fn read(path: &Path) -> Result<Entry, String> {
        let text = fs::read(path)
            .map_err(|e| format!("Could not read the desktop entry {}: {e}", path.display()))?;
        let mut entry = Entry::parse(&String::from_utf8_lossy(&text));
        entry.path = path.to_owned();
        entry.languages = environment_languages();
        Ok(entry)
    }

    pub fn parse(text: &str) -> Entry {
        let mut groups: Vec<(String, Vec<(String, String)>)> = Vec::new();
        for line in text.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            if let Some(name) = line.strip_prefix('[').and_then(|l| l.strip_suffix(']')) {
                groups.push((name.to_owned(), Vec::new()));
            } else if let Some((key, value)) = line.split_once('=') {
                if let Some((_, keys)) = groups.last_mut() {
                    keys.push((key.trim().to_owned(), value.trim_start().to_owned()));
                }
            }
        }
        Entry {
            path: PathBuf::new(),
            groups,
            languages: Vec::new(),
        }
    }

    /// <key> of <group>, as written.
    fn raw(&self, group: &str, key: &str) -> Option<&str> {
        self.groups
            .iter()
            .find(|(name, _)| name == group)?
            .1
            .iter()
            .find(|(k, _)| k == key)
            .map(|(_, v)| v.as_str())
    }

    /// <key> of <group> with its escapes undone (\s \n \t \r \\), in the
    /// language asked for when there is a translation.
    fn text(&self, group: &str, key: &str) -> Option<String> {
        for language in &self.languages {
            if let Some(value) = self.raw(group, &format!("{key}[{language}]")) {
                return Some(unescape(value));
            }
        }
        self.raw(group, key).map(unescape)
    }

    fn is_true(&self, key: &str) -> bool {
        self.raw("Desktop Entry", key) == Some("true")
    }

    pub fn has_action(&self, action: &str) -> bool {
        self.groups
            .iter()
            .any(|(name, _)| name == &format!("Desktop Action {action}"))
            && self
                .raw("Desktop Entry", "Actions")
                .is_some_and(|list| list.split(';').any(|a| a == action))
    }

    /// What the entry is called, in the language asked for.
    pub fn name(&self) -> String {
        self.text("Desktop Entry", "Name").unwrap_or_default()
    }

    /// What the entry is called, and its generic name: "Name - GenericName".
    pub fn description(&self) -> String {
        let name = self.text("Desktop Entry", "Name").unwrap_or_default();
        match self.text("Desktop Entry", "GenericName") {
            Some(generic) if !generic.is_empty() && generic != name => {
                format!("{name} - {generic}")
            }
            _ => name,
        }
    }

    pub fn terminal(&self) -> bool {
        self.is_true("Terminal")
    }

    pub fn working_directory(&self) -> Option<PathBuf> {
        self.text("Desktop Entry", "Path")
            .filter(|p| !p.is_empty())
            .map(PathBuf::from)
    }

    /// An error for an entry that must not run: hidden, or one whose TryExec
    /// program is not there.
    pub fn check_runnable(&self, workdir: Option<&Path>) -> Result<(), String> {
        let file = self.path.display();
        if self.is_true("Hidden") {
            return Err(format!("The desktop entry {file} is hidden"));
        }
        if let Some(program) = self
            .raw("Desktop Entry", "TryExec")
            .filter(|t| !t.is_empty())
        {
            if which_in(program, workdir).is_none() {
                return Err(format!(
                    "The desktop entry {file} is not for this computer: {program} is not installed"
                ));
            }
        }
        Ok(())
    }

    /// The Exec line of the entry, or of <action>, in words.
    pub fn exec(&self, action: Option<&str>) -> Result<Vec<String>, String> {
        let file = self.path.display();
        let group = match action {
            Some(action) => {
                if !self.has_action(action) {
                    return Err(format!("The desktop entry {file} has no action {action}"));
                }
                format!("Desktop Action {action}")
            }
            None => "Desktop Entry".to_owned(),
        };
        let line = self
            .text(&group, "Exec")
            .filter(|l| !l.trim().is_empty())
            .ok_or_else(|| match action {
                Some(action) => {
                    format!("The action {action} of the desktop entry {file} has no Exec")
                }
                None => format!("The desktop entry {file} has no Exec"),
            })?;
        let words = tokenize(&line);
        if words.first().is_none_or(|w| w.is_empty()) {
            return Err(format!("The desktop entry {file} has an empty Exec"));
        }
        Ok(words)
    }

    /// The Icon of the action when it has one, else the entry's.
    pub fn icon(&self, action: Option<&str>) -> Option<String> {
        action
            .and_then(|a| self.text(&format!("Desktop Action {a}"), "Icon"))
            .or_else(|| self.text("Desktop Entry", "Icon"))
            .filter(|i| !i.is_empty())
    }
}

/// A value with its escapes undone: \s is a space, \n, \t and \r what they
/// say, \\ a backslash. Any other backslash stays, with its character: in an
/// Exec line the quoting rule is applied after this one, and reads \" \` \$
/// itself.
fn unescape(value: &str) -> String {
    if !value.contains('\\') {
        return value.to_owned();
    }
    let mut out = String::new();
    let mut chars = value.chars();
    while let Some(ch) = chars.next() {
        if ch != '\\' {
            out.push(ch);
            continue;
        }
        match chars.next() {
            Some('s') => out.push(' '),
            Some('n') => out.push('\n'),
            Some('t') => out.push('\t'),
            Some('r') => out.push('\r'),
            Some('\\') => out.push('\\'),
            Some(other) => {
                out.push('\\');
                out.push(other);
            }
            None => out.push('\\'),
        }
    }
    out
}

/// An Exec line in words: separated by spaces, with "…" keeping spaces in a
/// word and a backslash in quotes keeping the next character as it is. The
/// specification asks for quotes around a few characters in a word; an
/// entry that does not quote them still runs, with them as they are.
pub fn tokenize(line: &str) -> Vec<String> {
    let mut words = Vec::new();
    let mut word = String::new();
    let mut in_word = false;
    let mut quoted = false;
    let mut chars = line.trim().chars();
    while let Some(ch) = chars.next() {
        if quoted {
            match ch {
                '"' => quoted = false,
                '\\' => word.extend(chars.next()),
                _ => word.push(ch),
            }
        } else if ch == '"' {
            quoted = true;
            in_word = true;
        } else if ch.is_whitespace() {
            if in_word {
                words.push(std::mem::take(&mut word));
                in_word = false;
            }
        } else {
            word.push(ch);
            in_word = true;
        }
    }
    if in_word {
        words.push(word);
    }
    words
}

/// The program <name> is: itself if it has a "/" and can run, else the first
/// executable file of that name in $PATH.
pub fn which(name: &str) -> Option<PathBuf> {
    which_in(name, None)
}

/// As `which`, with a name that has a "/" but is not absolute taken from
/// <base> when there is one: an entry with a Path runs its program there.
pub fn which_in(name: &str, base: Option<&Path>) -> Option<PathBuf> {
    use std::os::unix::fs::PermissionsExt;
    let runs = |p: &Path| {
        p.metadata()
            .is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
    };
    if name.contains('/') {
        let mut path = PathBuf::from(name);
        if let (false, Some(base)) = (path.is_absolute(), base) {
            path = base.join(path);
        }
        return runs(&path).then_some(path);
    }
    env::split_paths(&env::var_os("PATH")?)
        .map(|dir| dir.join(name))
        .find(|p| runs(p))
}

/// <argument> has a URL scheme (https:, file:, mailto:).
fn has_scheme(argument: &[u8]) -> bool {
    let Some(colon) = argument.iter().position(|&b| b == b':') else {
        return false;
    };
    let scheme = &argument[..colon];
    scheme.first().is_some_and(u8::is_ascii_alphabetic)
        && scheme
            .iter()
            .all(|b| b.is_ascii_alphanumeric() || b"+-.".contains(b))
}

/// <argument> as an absolute path, from the folder the launcher was run in:
/// the app may run in another (an entry's Path), and a name given relative
/// to this one must still be the same file there. A URL is left alone.
fn absolute(argument: &OsStr) -> OsString {
    let path = Path::new(argument);
    if path.is_absolute() || has_scheme(argument.as_bytes()) {
        return argument.to_owned();
    }
    match env::current_dir() {
        Ok(dir) => dir.join(path).into_os_string(),
        Err(_) => argument.to_owned(),
    }
}

/// <argument> as a URL: as it is when it has a scheme, else a file: URL of
/// the path it names.
fn to_url(argument: &OsStr) -> OsString {
    if has_scheme(argument.as_bytes()) {
        return argument.to_owned();
    }
    let path = absolute(argument);
    let mut url = String::from("file://");
    for &byte in path.as_bytes() {
        if byte.is_ascii_alphanumeric() || b"/_.-~".contains(&byte) {
            url.push(byte as char);
        } else {
            url.push_str(&format!("%{byte:02X}"));
        }
    }
    url.into()
}

/// <word> with <code> in it (%f) replaced by <value>.
fn fill(word: &str, code: &str, value: &OsStr) -> OsString {
    let mut out = Vec::new();
    for (at, piece) in word.split(code).enumerate() {
        if at > 0 {
            out.extend_from_slice(value.as_bytes());
        }
        out.extend_from_slice(piece.as_bytes());
    }
    OsString::from_vec(out)
}

/// What an entry knows that its codes ask for.
pub struct Fields<'a> {
    pub name: &'a str,
    pub path: &'a str,
    pub icon: Option<&'a str>,
}

/// The commands an Exec line comes to with <files> given: one, or one for
/// each of the files when the line takes a single one (%f, %u). The codes
/// are %f %F (files, as absolute paths), %u %U (URLs, a file's path made into
/// one), %i (--icon and the icon's name), %c (the name), %k (the entry's
/// file) and %% ; the deprecated %d %D %n %N %v %m are dropped with their
/// word. File names are kept as the bytes they are.
pub fn commands(
    exec: &[String],
    files: &[OsString],
    fields: &Fields,
) -> Result<Vec<Vec<OsString>>, String> {
    // Which word takes the files.
    let mut taker: Option<(usize, char)> = None;
    for (at, word) in exec.iter().enumerate().skip(1) {
        let mut chars = word.chars();
        while let Some(ch) = chars.next() {
            if ch != '%' {
                continue;
            }
            if let Some(code @ ('f' | 'F' | 'u' | 'U')) = chars.next() {
                if taker.is_some() {
                    return Err("The desktop entry's Exec asks for files twice".into());
                }
                if matches!(code, 'F' | 'U') && word.len() != 2 {
                    return Err(format!(
                        "The desktop entry's Exec has %{code} inside a word: {word}"
                    ));
                }
                taker = Some((at, code));
            }
        }
    }
    if !files.is_empty() && taker.is_none() {
        return Err("This desktop entry does not take files or addresses".into());
    }

    let one = |file: Option<&OsString>| -> Vec<OsString> {
        let mut out = vec![OsString::from(&exec[0])];
        for (at, word) in exec.iter().enumerate().skip(1) {
            if let Some((taking, code)) = taker {
                if at == taking {
                    match code {
                        'F' => out.extend(files.iter().map(|f| absolute(f))),
                        'U' => out.extend(files.iter().map(|f| to_url(f))),
                        _ => {
                            if let Some(file) = file {
                                let value = if code == 'u' {
                                    to_url(file)
                                } else {
                                    absolute(file)
                                };
                                out.push(fill(word, &format!("%{code}"), &value));
                            }
                        }
                    }
                    continue;
                }
            }
            if word == "%i" {
                if let Some(icon) = fields.icon {
                    out.push("--icon".into());
                    out.push(icon.into());
                }
                continue;
            }
            if let Some(word) = other_codes(word, fields) {
                out.push(word.into());
            }
        }
        out
    };

    Ok(match taker {
        Some((_, 'f' | 'u')) if files.len() > 1 => files.iter().map(|f| one(Some(f))).collect(),
        _ => vec![one(files.first())],
    })
}

/// A word with %c %k and %% done; none when it holds a deprecated code.
fn other_codes(word: &str, fields: &Fields) -> Option<String> {
    let mut out = String::new();
    let mut chars = word.chars();
    while let Some(ch) = chars.next() {
        if ch != '%' {
            out.push(ch);
            continue;
        }
        match chars.next() {
            Some('%') => out.push('%'),
            Some('c') => out.push_str(fields.name),
            Some('k') => out.push_str(fields.path),
            Some('d' | 'D' | 'n' | 'N' | 'v' | 'm') => return None,
            Some(other) => {
                out.push('%');
                out.push(other);
            }
            None => out.push('%'),
        }
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn words(items: &[&str]) -> Vec<String> {
        items.iter().map(|s| s.to_string()).collect()
    }

    /// `super::commands` with words as text, for the checks below.
    fn commands(
        exec: &[String],
        files: &[String],
        fields: &Fields,
    ) -> Result<Vec<Vec<String>>, String> {
        let files: Vec<OsString> = files.iter().map(OsString::from).collect();
        super::commands(exec, &files, fields).map(|all| {
            all.into_iter()
                .map(|c| {
                    c.into_iter()
                        .map(|w| w.to_string_lossy().into_owned())
                        .collect()
                })
                .collect()
        })
    }

    fn fields() -> Fields<'static> {
        Fields {
            name: "My App",
            path: "/usr/share/applications/app.desktop",
            icon: Some("app-icon"),
        }
    }

    #[test]
    fn exec_lines_are_split_by_the_specification() {
        assert_eq!(tokenize("app --flag  %U"), words(&["app", "--flag", "%U"]));
        assert_eq!(
            tokenize(r#"sh -c "echo \"hi there\" \$HOME" x"#),
            words(&["sh", "-c", "echo \"hi there\" $HOME", "x"])
        );
        assert_eq!(
            tokenize(r#""/opt/My App/run" --x"#),
            words(&["/opt/My App/run", "--x"])
        );
        assert_eq!(tokenize(r#"a "" b"#), words(&["a", "", "b"]));
        assert_eq!(
            tokenize("  env A=1 ~/x *  "),
            words(&["env", "A=1", "~/x", "*"])
        );
    }

    #[test]
    fn values_lose_their_escapes() {
        assert_eq!(unescape(r"a\sb\\c\nd"), "a b\\c\nd");
    }

    #[test]
    fn escapes_in_an_exec_line_reach_the_quoting_rule_as_the_specification_says() {
        // As written in the file: the string rule first (\\ is one backslash),
        // then the quoting rule (a backslash in quotes keeps the next character).
        let entry =
            Entry::parse("[Desktop Entry]\nExec=sh -c \"echo \\\\\"hi there\\\\\" \\\\$HOME\" x\n");
        assert_eq!(
            entry.exec(None).unwrap(),
            words(&["sh", "-c", "echo \"hi there\" $HOME", "x"])
        );
        // Four backslashes are one in the word.
        let entry = Entry::parse("[Desktop Entry]\nExec=echo \"a\\\\\\\\b\"\n");
        assert_eq!(entry.exec(None).unwrap(), words(&["echo", "a\\b"]));
        // \s is a space in the line before the words are split.
        let entry = Entry::parse("[Desktop Entry]\nExec=echo a\\sb\n");
        assert_eq!(entry.exec(None).unwrap(), words(&["echo", "a", "b"]));
    }

    #[test]
    fn a_relative_program_is_looked_for_in_the_entry_s_folder() {
        let dir = std::env::temp_dir().join(format!("nova-launch-rel-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let script = dir.join("run.sh");
        fs::write(&script, "#!/bin/sh\n").unwrap();
        fs::set_permissions(&script, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
        assert_eq!(which_in("./run.sh", Some(&dir)), Some(dir.join("./run.sh")));
        assert_eq!(which_in("./run.sh", None), None);
        assert_eq!(which_in("./gone.sh", Some(&dir)), None);
        let mut entry = Entry::parse("[Desktop Entry]\nExec=./run.sh\nTryExec=./run.sh\n");
        entry.path = PathBuf::from("/x/app.desktop");
        assert!(entry.check_runnable(None).is_err());
        assert!(entry.check_runnable(Some(&dir)).is_ok());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn relative_files_are_made_absolute_from_where_the_launcher_ran() {
        let here = env::current_dir().unwrap();
        let first = here.join("notes/a b.txt").to_string_lossy().into_owned();
        assert_eq!(
            commands(
                &words(&["v", "--f=%f"]),
                &words(&["notes/a b.txt"]),
                &fields()
            )
            .unwrap(),
            vec![vec!["v".to_owned(), format!("--f={first}")]]
        );
        assert_eq!(
            commands(&words(&["v", "%F"]), &words(&["x"]), &fields()).unwrap(),
            vec![vec![
                "v".to_owned(),
                here.join("x").to_string_lossy().into_owned()
            ]]
        );
        let url = commands(&words(&["v", "%u"]), &words(&["x y"]), &fields()).unwrap();
        assert!(url[0][1].starts_with("file:///") && url[0][1].ends_with("/x%20y"));
        // A URL stays as it is.
        assert_eq!(
            commands(
                &words(&["v", "%f"]),
                &words(&["https://e.org/a"]),
                &fields()
            )
            .unwrap(),
            vec![words(&["v", "https://e.org/a"])]
        );
    }

    #[test]
    fn a_file_name_that_is_not_text_reaches_the_app_as_it_is() {
        let name = OsString::from_vec(b"/tmp/caf\xe9 \xff.txt".to_vec());
        let all =
            super::commands(&words(&["v", "%f"]), std::slice::from_ref(&name), &fields()).unwrap();
        assert_eq!(all, vec![vec![OsString::from("v"), name.clone()]]);
        let all = super::commands(
            &words(&["v", "--x=%f"]),
            std::slice::from_ref(&name),
            &fields(),
        )
        .unwrap();
        assert_eq!(all[0][1].as_bytes(), b"--x=/tmp/caf\xe9 \xff.txt");
        let all = super::commands(&words(&["v", "%U"]), &[name], &fields()).unwrap();
        assert_eq!(all[0][1], OsString::from("file:///tmp/caf%E9%20%FF.txt"));
    }

    #[test]
    fn one_file_fills_f_and_u() {
        let exec = words(&["viewer", "--open=%f"]);
        let files = words(&["/tmp/a b.txt"]);
        assert_eq!(
            commands(&exec, &files, &fields()).unwrap(),
            vec![words(&["viewer", "--open=/tmp/a b.txt"])]
        );
        let exec = words(&["viewer", "%u"]);
        assert_eq!(
            commands(&exec, &files, &fields()).unwrap(),
            vec![words(&["viewer", "file:///tmp/a%20b.txt"])]
        );
        assert_eq!(
            commands(&exec, &words(&["https://example.org/x"]), &fields()).unwrap(),
            vec![words(&["viewer", "https://example.org/x"])]
        );
    }

    #[test]
    fn several_files_start_one_instance_each_for_f_and_u_and_one_for_the_capitals() {
        let files = words(&["/a", "/b"]);
        assert_eq!(
            commands(&words(&["v", "%f"]), &files, &fields()).unwrap(),
            vec![words(&["v", "/a"]), words(&["v", "/b"])]
        );
        assert_eq!(
            commands(&words(&["v", "-x", "%U"]), &files, &fields()).unwrap(),
            vec![words(&["v", "-x", "file:///a", "file:///b"])]
        );
        assert_eq!(
            commands(&words(&["v", "%F"]), &files, &fields()).unwrap(),
            vec![words(&["v", "/a", "/b"])]
        );
    }

    #[test]
    fn no_file_drops_the_word_that_would_hold_it() {
        assert_eq!(
            commands(&words(&["v", "--new", "%U"]), &[], &fields()).unwrap(),
            vec![words(&["v", "--new"])]
        );
        assert_eq!(
            commands(&words(&["v", "--f=%f"]), &[], &fields()).unwrap(),
            vec![words(&["v"])]
        );
    }

    #[test]
    fn the_other_codes() {
        let exec = words(&["app", "%i", "--name=%c", "%k", "100%%", "%d", "x%Dy", "%n"]);
        assert_eq!(
            commands(&exec, &[], &fields()).unwrap(),
            vec![words(&[
                "app",
                "--icon",
                "app-icon",
                "--name=My App",
                "/usr/share/applications/app.desktop",
                "100%"
            ])]
        );
        let mut bare = fields();
        bare.icon = None;
        assert_eq!(
            commands(&words(&["app", "%i"]), &[], &bare).unwrap(),
            vec![words(&["app"])]
        );
    }

    #[test]
    fn files_for_an_entry_that_takes_none_are_an_error() {
        let error = commands(&words(&["app"]), &words(&["/a"]), &fields()).unwrap_err();
        assert!(error.contains("does not take files"), "{error}");
        assert!(commands(&words(&["app", "%f", "%u"]), &[], &fields()).is_err());
        assert!(commands(&words(&["app", "x%F"]), &[], &fields()).is_err());
    }

    #[test]
    fn an_entry_is_read_with_its_actions_and_translations() {
        let mut entry = Entry::parse(
            "# comment\n[Desktop Entry]\nName=Files\nName[de]=Dateien\nGenericName=File Manager\nExec=files %U\nTerminal=true\nActions=new;gone;\nPath=/tmp\nIcon=files\n\n[Desktop Action new]\nName=New\nExec=files --new\n",
        );
        assert_eq!(entry.description(), "Files - File Manager");
        entry.languages = locale_keys("de_DE.UTF-8");
        assert_eq!(entry.description(), "Dateien - File Manager");
        assert!(entry.terminal());
        assert_eq!(entry.working_directory(), Some(PathBuf::from("/tmp")));
        assert_eq!(entry.exec(None).unwrap(), words(&["files", "%U"]));
        assert_eq!(entry.exec(Some("new")).unwrap(), words(&["files", "--new"]));
        assert!(entry.exec(Some("gone")).unwrap_err().contains("no action"));
        assert!(entry.exec(Some("other")).unwrap_err().contains("no action"));
        assert_eq!(entry.icon(Some("new")).as_deref(), Some("files"));
    }

    #[test]
    fn a_name_that_is_its_generic_name_is_said_once() {
        let entry =
            Entry::parse("[Desktop Entry]\nName=Calculator\nGenericName=Calculator\nExec=c\n");
        assert_eq!(entry.description(), "Calculator");
    }

    #[test]
    fn locales_name_their_translations() {
        assert_eq!(
            locale_keys("de_AT.UTF-8@euro"),
            ["de_AT@euro", "de_AT", "de@euro", "de"]
        );
        assert_eq!(locale_keys("en_US.UTF-8"), ["en_US", "en"]);
        assert!(locale_keys("C").is_empty());
    }

    #[test]
    fn an_id_is_found_in_subfolders_by_its_dashes() {
        let dir = std::env::temp_dir().join(format!("nova-launch-find-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join("kde/sub")).unwrap();
        fs::write(dir.join("kde/sub/app.desktop"), "").unwrap();
        fs::write(dir.join("plain.desktop"), "").unwrap();
        let dirs = vec![dir.clone()];
        assert_eq!(
            find(&dirs, "plain.desktop"),
            Some(dir.join("plain.desktop"))
        );
        assert_eq!(
            find(&dirs, "kde-sub-app.desktop"),
            Some(dir.join("kde/sub/app.desktop"))
        );
        assert_eq!(find(&dirs, "kde-sub-gone.desktop"), None);
        assert_eq!(
            id_of(&dirs, &dir.join("kde/sub/app.desktop")),
            "kde-sub-app.desktop"
        );
        assert_eq!(id_of(&dirs, Path::new("/elsewhere/x.desktop")), "x.desktop");
        let _ = fs::remove_dir_all(&dir);
    }
}
