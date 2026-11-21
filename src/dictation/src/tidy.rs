//! Parakeet's words, ready to paste: one line, without the sounds made while
//! thinking ("uh", "um") and the words said twice by a stutter, with what
//! was taken back ("scratch that") taken out, the user's own spellings
//! (vocab.rs), and a space after a finished sentence, so that the next
//! dictation does not run into it.

use crate::settle::{bare, is_mark};
use crate::vocab::Vocab;

/// Sounds made while thinking, in English and Italian, which Parakeet writes
/// down as words. "Eh?" is a question, and stays.
const FILLERS: [&str; 14] = [
    "uh", "uhh", "uhm", "um", "umm", "hm", "hmm", "mm", "mmm", "er", "erm", "eh", "ehm", "ehmm",
];

/// Words said twice on purpose ("had had", "no no", "very very"), which a
/// stutter's doubled word is not.
const DOUBLES: [&str; 35] = [
    "that", "had", "is", "do", "very", "really", "so", "no", "yes", "bye", "oh", "ha", "haha",
    "well", "now", "ok", "okay", "go", "more", "many", "much", "please", "ah", "si", "sì", "molto",
    "piano", "pian", "ciao", "bene", "va", "tanto", "troppo", "mai", "dai",
];

/// What takes back the words said since the last comma or full stop, said
/// as a clause of its own.
const TAKE_BACKS: [&[&str]; 2] = [&["scratch", "that"], &["never", "mind", "that"]];

/// The dictation's words, as they are pasted.
pub fn clean(text: &str, vocab: &Vocab) -> String {
    let words: Vec<String> = text.split_whitespace().map(str::to_owned).collect();
    let words = vocab.apply(tidy(take_back(words)));
    let s = words.join(" ");
    if s.is_empty() {
        return s;
    }
    if s.ends_with(['.', '!', '?', '…']) {
        s + " "
    } else {
        s
    }
}

fn ends_sentence(word: &str) -> bool {
    word.ends_with(['.', '!', '?'])
}

fn ends_clause(word: &str) -> bool {
    word.ends_with(['.', '!', '?', ',', ';', ':', '…'])
}

/// <word> with its first letter a capital, after any mark before it, when
/// it is all in lower case ("iPhone" stays).
fn capital(word: &str) -> String {
    if word.chars().any(char::is_uppercase) {
        return word.to_owned();
    }
    match word.char_indices().find(|(_, c)| c.is_alphabetic()) {
        Some((i, c)) => format!(
            "{}{}{}",
            &word[..i],
            c.to_uppercase(),
            &word[i + c.len_utf8()..]
        ),
        None => word.to_owned(),
    }
}

/// The words without the clause before each "scratch that" (or "never mind
/// that"), said as a clause of its own: back to the comma or full stop
/// before it, or the start. "Meet me at five. Scratch that. Meet me at six."
/// is "Meet me at six." It runs before the fillers go (their commas are
/// where clauses end), so a clause of only fillers is passed over.
pub fn take_back(mut words: Vec<String>) -> Vec<String> {
    let mut i = 0;
    while i < words.len() {
        let Some(len) = TAKE_BACKS.iter().map(|p| p.len()).find(|&len| {
            i + len <= words.len()
                && TAKE_BACKS.iter().any(|phrase| {
                    phrase.len() == len && phrase.iter().zip(&words[i..i + len]).all(|(p, w)| bare(w) == *p)
                })
                // Its words run on, with no mark between them.
                && words[i..i + len - 1].iter().all(|w| !ends_clause(w))
        }) else {
            i += 1;
            continue;
        };
        let alone = (i == 0 || ends_clause(&words[i - 1]))
            && (i + len == words.len() || ends_clause(&words[i + len - 1]));
        if !alone {
            i += 1;
            continue;
        }
        // The clause before it: back to the word after the last mark, and
        // past a clause of only fillers ("five, um, scratch that") to the
        // one before that, which is what is taken back.
        let mut start = clause_start(&words, i);
        while start > 0 && words[start..i].iter().all(|w| filler(w)) {
            start = clause_start(&words, start);
        }
        let dropped_end = words[start..i]
            .iter()
            .rev()
            .find_map(|w| w.chars().last().filter(|c| matches!(c, '.' | '!' | '?')));
        words.drain(start..i + len);
        if start > 0 {
            // "five, then go. Scratch that." is "five."
            if let Some(end) = dropped_end {
                let before = &mut words[start - 1];
                if before.ends_with([',', ';', ':']) {
                    before.pop();
                    before.push(end);
                }
            }
        }
        // What follows starts a sentence, if what was taken back did.
        if (start == 0 || ends_sentence(&words[start - 1])) && start < words.len() {
            words[start] = capital(&words[start]);
        }
        i = start;
    }
    words
}

/// Where the clause that ends before <end> begins: the word after the last
/// mark before it, or the first.
fn clause_start(words: &[String], end: usize) -> usize {
    let mut start = end;
    while start > 0 && (start == end || !ends_clause(&words[start - 1])) {
        start -= 1;
    }
    start
}

/// Whether <word> is a sound made while thinking ("Eh?" is a question).
fn filler(word: &str) -> bool {
    let plain = bare(word);
    FILLERS.contains(&plain.as_str()) && !(plain == "eh" && word.ends_with('?'))
}

/// <words> without "uh" and "um", and with a stuttered word ("at at six",
/// "I, I think") said once. A filler takes its comma with it, and the comma
/// before it ("went, uh, home" is "went home"); one that began a sentence
/// passes its capital on, and one that ended it its full stop.
pub fn tidy(words: Vec<String>) -> Vec<String> {
    let mut out: Vec<String> = Vec::with_capacity(words.len());
    let mut starts_sentence = true;
    let mut capital_next = false;
    for word in words {
        let plain = bare(&word);
        let end = ends_sentence(&word);
        if filler(&word) {
            if let Some(last) = out.last_mut() {
                if end && !ends_sentence(last) {
                    let mark = word.chars().last().unwrap_or('.');
                    let trimmed = last.trim_end_matches([',', ';', ':']).len();
                    last.truncate(trimmed);
                    last.push(mark);
                } else if word.ends_with(',') && last.ends_with(',') {
                    last.pop();
                }
            }
            if starts_sentence || end {
                capital_next = true;
            }
            if end {
                starts_sentence = true;
            }
            continue;
        }
        let stutter = out.last().is_some_and(|previous| {
            !plain.is_empty()
                && bare(previous) == plain
                && !previous
                    .trim_end_matches(',')
                    .contains(['.', '!', '?', ';', ':'])
                && !DOUBLES.contains(&plain.as_str())
                && !plain.chars().all(|c| c.is_ascii_digit())
        });
        if stutter {
            // The first of the two goes, with the capital it had.
            let previous = out.pop().unwrap_or_default();
            let had_capital = previous
                .chars()
                .find(|c| !is_mark(*c))
                .is_some_and(char::is_uppercase);
            out.push(if had_capital {
                capital(&word)
            } else {
                word.clone()
            });
        } else if capital_next {
            out.push(capital(&word));
        } else {
            out.push(word.clone());
        }
        capital_next = false;
        starts_sentence = end;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn c(text: &str) -> String {
        clean(text, &Vocab::default())
    }

    // The shell's tests of DictationModel.clean (tests/qml/dictation-test.qml),
    // which this replaces.
    #[test]
    fn one_line_single_spaces_and_a_space_after_a_finished_sentence() {
        assert_eq!(
            c(" And so,  my fellow\nAmericans "),
            "And so, my fellow Americans"
        );
        assert_eq!(
            c("Ask not what your country can do for you."),
            "Ask not what your country can do for you. "
        );
        assert_eq!(c("¿Qué tal?"), "¿Qué tal? ");
        assert_eq!(c("¡Hola!"), "¡Hola! ");
        assert_eq!(c(""), "");
        assert_eq!(c("  \n "), "");
    }

    #[test]
    fn a_stuttered_word_is_said_once() {
        assert_eq!(
            c("I have an appointment at at 6 and and then I I see."),
            "I have an appointment at 6 and then I see. "
        );
        assert_eq!(c("I, I think so."), "I think so. ");
    }

    #[test]
    fn fillers_go_with_their_commas_and_pass_a_capital_or_a_full_stop_on() {
        assert_eq!(c("Um, so we went, uh, home."), "So we went home. ");
        assert_eq!(c("I went home, um."), "I went home. ");
        assert_eq!(
            c("Ehm, allora ci vediamo alle cinque."),
            "Allora ci vediamo alle cinque. "
        );
        assert_eq!(c("Eh? What did you say?"), "Eh? What did you say? ");
        assert_eq!(c("um"), "");
    }

    #[test]
    fn words_said_twice_on_purpose_and_numbers_stay() {
        assert_eq!(
            c("That that is fine, I had had enough. No no no, very very good."),
            "That that is fine, I had had enough. No no no, very very good. "
        );
        assert_eq!(c("It is 2 2 km away."), "It is 2 2 km away. ");
    }

    // A name written with a small letter first keeps it at a sentence's
    // start: the shell's tidy made "iPhone" "IPhone" there.
    #[test]
    fn a_sentence_that_starts_with_a_name_keeps_its_spelling() {
        assert_eq!(c("Done. iPhone sync is on."), "Done. iPhone sync is on. ");
        assert_eq!(c("Um, iPhone sync is on."), "iPhone sync is on. ");
    }

    #[test]
    fn scratch_that_takes_back_the_clause_before_it() {
        assert_eq!(
            c("Meet me at five. Scratch that. Meet me at six."),
            "Meet me at six. "
        );
        assert_eq!(c("I'll bring wine, scratch that, beer."), "Beer. ");
        assert_eq!(
            c("We leave at noon, then lunch. Scratch that."),
            "We leave at noon. "
        );
        assert_eq!(c("Call Anna. Never mind that. Call Marco."), "Call Marco. ");
        assert_eq!(c("Scratch that. Hello."), "Hello. ");
        assert_eq!(c("One. Two. Scratch that. Scratch that. Three."), "Three. ");
    }

    // A clause of only fillers is not the one taken back: the one before it is.
    #[test]
    fn scratch_that_after_a_filler_takes_back_the_clause_before_the_filler() {
        assert_eq!(c("Meet me at five, um, scratch that."), "");
        assert_eq!(c("Meet me at five, um, scratch that, six."), "Six. ");
        assert_eq!(
            c("Meet me at five. Um. Scratch that. Meet me at six."),
            "Meet me at six. "
        );
        assert_eq!(
            c("Lunch first. Then a walk, uh. Um, scratch that. A nap."),
            "Lunch first. A nap. "
        );
        assert_eq!(c("Um. Scratch that. Hello."), "Hello. ");
        assert_eq!(
            c("We leave at noon, then lunch. Um, scratch that."),
            "We leave at noon. "
        );
        assert_eq!(c("Hello. Eh? Scratch that."), "Hello. ");
    }

    #[test]
    fn scratch_that_inside_a_sentence_is_words() {
        assert_eq!(c("Please scratch that itch."), "Please scratch that itch. ");
        assert_eq!(
            c("I said scratch that, then left."),
            "I said scratch that, then left. "
        );
    }
}
