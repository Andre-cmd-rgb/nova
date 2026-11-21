//! The user's own spellings: ~/.config/nova/dictation/vocab.toml, words
//! Parakeet hears as something else and how to write them.
//!
//!   # What Parakeet writes = how it is written
//!   "hyper land" = "Hyprland"
//!   "quick shell" = "Quickshell"
//!   nova = "Nova"
//!
//! A line each, as in TOML: the words as Parakeet writes them (quoted when
//! they hold a space), in any case, and the spelling, quoted. The words are
//! matched whole, in any case, with the marks around them kept ("hyper
//! land," is "Hyprland,"). A line that is not of this form is left out and
//! said in the journal; a [section] line is passed over, so the file can
//! grow sections without old ones breaking.

use std::path::Path;

use crate::settle::{bare, is_mark};

#[derive(Debug, Clone, Default, PartialEq)]
pub struct Vocab {
    /// Each entry's words, bare (as settle::bare makes them), and its spelling.
    entries: Vec<(Vec<String>, String)>,
}

/// A TOML basic string's inside, its escapes read; none if it is not one.
fn unquote(s: &str) -> Option<String> {
    let inner = s.strip_prefix('"')?.strip_suffix('"')?;
    let mut out = String::new();
    let mut chars = inner.chars();
    while let Some(c) = chars.next() {
        match c {
            '\\' => match chars.next()? {
                '"' => out.push('"'),
                '\\' => out.push('\\'),
                'n' => out.push('\n'),
                't' => out.push('\t'),
                'u' => {
                    let hex: String = chars.by_ref().take(4).collect();
                    out.push(char::from_u32(u32::from_str_radix(&hex, 16).ok()?)?);
                }
                _ => return None,
            },
            '"' => return None,
            c => out.push(c),
        }
    }
    Some(out)
}

/// The value part of a line, up to a comment after it.
fn value(s: &str) -> Option<String> {
    let s = s.trim();
    // The closing quote is the last unescaped one; a comment may follow it.
    let mut escaped = false;
    for (i, c) in s.char_indices().skip(1) {
        match c {
            '\\' if !escaped => escaped = true,
            '"' if !escaped => {
                let rest = s[i + 1..].trim();
                return (rest.is_empty() || rest.starts_with('#'))
                    .then(|| unquote(&s[..=i]))
                    .flatten();
            }
            _ => escaped = false,
        }
    }
    None
}

impl Vocab {
    /// The file's entries; none where there is no file.
    pub fn read(path: &Path) -> Vocab {
        match std::fs::read_to_string(path) {
            Ok(text) => {
                let (vocab, wrong) = Vocab::parse(&text);
                for line in wrong {
                    eprintln!(
                        "nova-dictationd: {}:{line}: not \"words\" = \"spelling\", left out",
                        path.display()
                    );
                }
                vocab
            }
            Err(_) => Vocab::default(),
        }
    }

    /// The entries of <text>, and the numbers of the lines that are not entries.
    pub fn parse(text: &str) -> (Vocab, Vec<usize>) {
        let mut entries = Vec::new();
        let mut wrong = Vec::new();
        for (n, line) in text.lines().enumerate() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') || line.starts_with('[') {
                continue;
            }
            let entry = line.split_once('=').and_then(|(key, spelling)| {
                let key = key.trim();
                let key = if key.starts_with('"') {
                    unquote(key)?
                } else {
                    key.to_owned()
                };
                let words: Vec<String> = key
                    .split_whitespace()
                    .map(bare)
                    .filter(|w| !w.is_empty())
                    .collect();
                let spelling = value(spelling)?;
                (!words.is_empty() && !spelling.trim().is_empty())
                    .then_some((words, spelling.trim().to_owned()))
            });
            match entry {
                Some(entry) => entries.push(entry),
                None => wrong.push(n + 1),
            }
        }
        // The longest first: "quick shell app" before "quick shell".
        entries.sort_by_key(|(words, _)| std::cmp::Reverse(words.len()));
        (Vocab { entries }, wrong)
    }

    /// <words> with each entry's words written as the entry says.
    pub fn apply(&self, words: Vec<String>) -> Vec<String> {
        if self.entries.is_empty() {
            return words;
        }
        let bares: Vec<String> = words.iter().map(|w| bare(w)).collect();
        let mut out = Vec::with_capacity(words.len());
        let mut i = 0;
        'words: while i < words.len() {
            for (entry, spelling) in &self.entries {
                let n = entry.len();
                if i + n > words.len() || bares[i..i + n] != entry[..] {
                    continue;
                }
                // Marks inside the phrase ("hyper, land", "hyper (land)")
                // are not one name: only the first word's before it and the
                // last's after it are kept around the spelling.
                if words[i..i + n - 1].iter().any(|w| w.ends_with(is_mark))
                    || words[i + 1..i + n].iter().any(|w| w.starts_with(is_mark))
                {
                    continue;
                }
                let first = &words[i];
                let last = &words[i + n - 1];
                let before = &first[..first.len() - first.trim_start_matches(is_mark).len()];
                let after = &last[last.trim_end_matches(is_mark).len()..];
                out.push(format!("{before}{spelling}{after}"));
                i += n;
                continue 'words;
            }
            out.push(words[i].clone());
            i += 1;
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn words(s: &str) -> Vec<String> {
        s.split_whitespace().map(str::to_owned).collect()
    }

    fn apply(vocab: &str, text: &str) -> String {
        Vocab::parse(vocab).0.apply(words(text)).join(" ")
    }

    const VOCAB: &str = r#"
# What Parakeet writes = how it is written
"hyper land" = "Hyprland"
"quick shell" = "Quickshell"   # the shell
nova = "Nova"
[later]
"anti gravity" = "Antigravity"
"#;

    #[test]
    fn whole_words_in_any_case_become_the_users_spelling_marks_kept() {
        assert_eq!(
            apply(VOCAB, "I use Hyper Land with quick shell, on nova."),
            "I use Hyprland with Quickshell, on Nova."
        );
        assert_eq!(apply(VOCAB, "(hyper land)!"), "(Hyprland)!");
        assert_eq!(
            apply(VOCAB, "Supernova is not nova-ish."),
            "Supernova is not nova-ish."
        );
        assert_eq!(apply(VOCAB, "anti gravity"), "Antigravity");
    }

    #[test]
    fn a_mark_inside_the_words_breaks_the_name() {
        assert_eq!(apply(VOCAB, "hyper, land"), "hyper, land");
        assert_eq!(apply(VOCAB, "hyper (land)"), "hyper (land)");
        assert_eq!(apply(VOCAB, "(hyper) land"), "(hyper) land");
        assert_eq!(apply(VOCAB, "quick \"shell\""), "quick \"shell\"");
    }

    #[test]
    fn the_longest_entry_wins() {
        let vocab =
            "\"quick shell\" = \"Quickshell\"\n\"quick shell plugins\" = \"Quickshell plugins\"\n";
        assert_eq!(apply(vocab, "quick shell plugins"), "Quickshell plugins");
    }

    #[test]
    fn lines_that_are_not_entries_are_left_out_and_named() {
        let (vocab, wrong) = Vocab::parse(
            "ok = \"OK\"\nbroken\n\"open = \"x\"\nempty = \"\"\nescaped = \"say \\\"hi\\\"\"\n",
        );
        assert_eq!(wrong, vec![2, 3, 4]);
        assert_eq!(vocab.apply(words("ok escaped")).join(" "), "OK say \"hi\"");
    }

    #[test]
    fn no_file_is_no_entries() {
        assert_eq!(
            Vocab::read(Path::new("/nonexistent/nova/vocab.toml")),
            Vocab::default()
        );
    }
}
