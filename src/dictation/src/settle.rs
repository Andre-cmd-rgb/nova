//! Hearing it while it is said: which words are settled.
//!
//! While the dictation goes on, the recording is heard again and again from
//! where the text not yet settled starts (`from`). A sentence settles once a
//! hearing has words after it and the hearing before heard it the same, word
//! for word: in any case and with or without a comma, but with the same
//! sentence's ends (same_word). Parakeet hears a piece of speech alone
//! as a whole sentence, with a full stop and a capital; so a part is never
//! settled on a hearing that ends with it. A pause to think in mid-sentence
//! is heard with what follows, and gets no full stop: the hearing made during
//! the pause ends "at.", the next, with the words after the pause, "at five",
//! and the two disagree, so nothing settles until the sentence has ended and
//! been heard so twice.
//!
//! Once a sentence settles, the recording is cut in the pause after it and
//! the next hearings start there: what is heard again stays short, however
//! long the dictation, and the end has only the last sentence or two to hear.
//! The rest of the hearing that settled it, after the cut, is what the next
//! hearing has to agree with; its words were heard with the same audio
//! around them, and must come out the same from the new start to settle.
//! Where hearings never agree (a television behind the voice), the part not
//! yet settled would grow to the whole dictation: past dictation.rs's
//! UNSETTLED, its oldest part settles by force (Heard::force), never its
//! newest seconds.

use crate::look::{Kind, Look, Piece};

/// How long, in seconds, the part not yet settled grows before a comma will
/// do as well as a sentence's end: a long sentence is cut at a comma rather
/// than heard whole at the end.
pub const SOFT_AFTER: f64 = 25.0;

/// A full stop after these is not a sentence's end.
const ABBREVIATIONS: [&str; 16] = [
    "dr", "mr", "mrs", "ms", "st", "prof", "jr", "sr", "vs", "etc", "sig", "dott", "ing", "avv",
    "geom", "rag",
];

/// What has been heard so far.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Heard {
    /// The settled text.
    pub text: String,
    /// The second of the recording where the settled text ends, where the
    /// next hearing starts.
    pub from: f64,
    /// What the next hearing from <from> is to agree with.
    last: Option<Look>,
    /// The newest hearing's words after <from>.
    pub tail: String,
    /// The second the newest hearing heard up to.
    pub until: f64,
}

/// A word as compared: lower case, without the marks around it.
pub fn bare(word: &str) -> String {
    word.trim_matches(is_mark).to_lowercase()
}

/// The marks a word can carry before or after it.
pub fn is_mark(c: char) -> bool {
    matches!(
        c,
        '.' | ','
            | '!'
            | '?'
            | ';'
            | ':'
            | '…'
            | '"'
            | '“'
            | '”'
            | '\''
            | '‘'
            | '’'
            | '«'
            | '»'
            | '('
            | ')'
            | '['
            | ']'
            | '¿'
            | '¡'
            | '-'
    )
}

/// Whether two hearings wrote the same word. Parakeet writes a name with
/// capitals in one hearing and without in the next ("Mission Control",
/// "mission control"), and puts a comma in or leaves it out; held to those,
/// nothing after the first sentence of a recording settled, and its end was
/// heard whole. A sentence's end is held to: a full stop where the other
/// hearing went on is a pause to think, not an end.
fn same_word(a: &str, b: &str) -> bool {
    let soft = |w: &str| w.trim_end_matches([',', ';', ':']).to_lowercase();
    soft(a) == soft(b)
}

/// How many of <look>'s pieces, from the first, <before> heard the same,
/// word for word (same_word): its words start with theirs.
fn agreeing(look: &Look, before: &Look) -> usize {
    let said = before.text();
    let mut said = said.split_whitespace();
    look.pieces
        .iter()
        .take_while(|piece| {
            piece
                .text
                .split_whitespace()
                .all(|word| said.next().is_some_and(|other| same_word(word, other)))
        })
        .count()
}

pub(crate) fn sentence_end(piece: &Piece) -> bool {
    if piece.kind != Kind::Sentence {
        return false;
    }
    let last = piece.text.rsplit(' ').next().unwrap_or("");
    !(last.ends_with('.') && ABBREVIATIONS.contains(&bare(last).as_str()))
}

impl Heard {
    pub fn new() -> Heard {
        Heard::default()
    }

    /// Whether <look>, a hearing from <from>, tells anything new: it starts
    /// where the unsettled text does and heard further than the last one.
    pub fn useful(&self, from: f64, look: &Look) -> bool {
        from == self.from && look.end > self.from && look.end >= self.until
    }

    /// Takes in a hearing from <self.from>: settles its pieces the one before
    /// heard the same, up to the last one that ends a sentence (or, once the
    /// part is SOFT_AFTER long, a clause).
    pub fn settle(&mut self, look: Look) {
        let agreed = self
            .last
            .as_ref()
            .map_or(0, |before| agreeing(&look, before));
        let long = look.end - self.from >= SOFT_AFTER;
        let keep = (0..agreed)
            .filter(|&i| {
                sentence_end(&look.pieces[i]) || (long && look.pieces[i].kind == Kind::Soft)
            })
            .map(|i| i + 1)
            .max()
            .unwrap_or(0);
        self.until = look.end;
        if keep == 0 {
            self.tail = look.text();
            self.last = Some(look);
            return;
        }
        let after = self.take(look, keep);
        self.last = Some(after);
    }

    /// Settles <look>'s first <keep> pieces whatever the hearing before it
    /// heard: the part not yet settled has grown too long (dictation.rs,
    /// UNSETTLED). Nothing after them settles until two new hearings agree.
    pub fn force(&mut self, look: Look, keep: usize) {
        self.take(look, keep);
        self.last = None;
    }

    /// Settles <words> by force, up to <at> seconds into the recording, and
    /// <tail> is the newest hearing's words after it: where no part of the
    /// hearing ends in time, its whole words, or none, where it heard none.
    pub fn force_to(&mut self, words: &str, at: f64, tail: String) {
        self.text = join(&self.text, words);
        self.from = at;
        self.tail = tail;
        self.last = None;
    }

    /// Settles <look>'s first <keep> pieces; the rest of it.
    fn take(&mut self, look: Look, keep: usize) -> Look {
        let kept: Vec<&str> = look.pieces[..keep]
            .iter()
            .map(|p| p.text.as_str())
            .collect();
        self.text = join(&self.text, &kept.join(" "));
        self.from = look.pieces[keep - 1].at;
        let after = Look {
            end: look.end,
            pieces: look.pieces[keep..].to_vec(),
            rest: look.rest,
        };
        self.tail = after.text();
        after
    }

    /// Whether the newest hearing heard all that was said: the voice was last
    /// heard at <voice_at> seconds into the recording, well before its end.
    pub fn heard_all(&self, voice_at: f64) -> bool {
        self.until > 0.0 && voice_at + 0.4 < self.until
    }

    /// The settled text and the newest hearing's words after it.
    pub fn words(&self) -> String {
        join(&self.text, &self.tail)
    }
}

fn upper(c: char) -> bool {
    c.is_uppercase()
}

/// <next> after <text>. After a cut at a comma, Parakeet starts the next part
/// with a capital it would not have given it mid-sentence. What looks like a
/// name keeps it: "I", a word in capitals, an abbreviation ("Dr."), and a
/// word before another with a capital ("Lieutenant Colonel").
pub fn join(text: &str, next: &str) -> String {
    if text.is_empty() {
        return next.to_owned();
    }
    if next.is_empty() {
        return text.to_owned();
    }
    let mut words = next.split(' ');
    let first = words.next().unwrap_or("");
    let second = words.next().unwrap_or("");
    let mut chars = first.chars();
    let head = chars.next();
    let tail: String = chars.collect();
    let is_i = first == "I"
        || (first.starts_with('I')
            && first[1..].starts_with(['\'', '’', ',', '.', '!', '?', ';', ':']));
    let lower = !text.ends_with(['.', '!', '?'])
        && !is_i
        && !first.ends_with('.')
        && head.is_some_and(upper)
        && tail == tail.to_lowercase()
        && !second.chars().next().is_some_and(upper);
    if lower {
        let head = head.unwrap();
        format!("{text} {}{}", head.to_lowercase(), &next[head.len_utf8()..])
    } else {
        format!("{text} {next}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn piece(at: f64, kind: Kind, text: &str) -> Piece {
        Piece {
            at,
            end: at - 0.1,
            kind,
            text: text.into(),
        }
    }

    fn sentence(at: f64, text: &str) -> Piece {
        piece(at, Kind::Sentence, text)
    }

    fn look(end: f64, pieces: Vec<Piece>, rest: &str) -> Look {
        Look {
            end,
            pieces,
            rest: rest.into(),
        }
    }

    fn houston(end: f64, at: f64, rest: &str) -> Look {
        look(
            end,
            vec![
                sentence(at, "My fellow Americans, this day has come."),
                piece(11.4, Kind::Soft, "At nine o'clock,"),
            ],
            rest,
        )
    }

    #[test]
    fn one_hearing_settles_nothing_there_is_nothing_to_agree_with() {
        let mut heard = Heard::new();
        let first = houston(21.4, 8.8, "mission control");
        heard.settle(first.clone());
        assert_eq!(heard.text, "");
        assert_eq!(heard.from, 0.0);
        assert_eq!(heard.tail, first.text());
        assert_eq!(heard.until, 21.4);
    }

    #[test]
    fn two_hearings_agreeing_on_a_sentence_settle_it_cut_where_the_newer_says() {
        let mut heard = Heard::new();
        heard.settle(houston(21.4, 8.8, "mission control"));
        heard.settle(houston(23.0, 8.84, "mission control in Houston"));
        assert_eq!(heard.text, "My fellow Americans, this day has come.");
        assert_eq!(heard.from, 8.84);
        // A comma waits.
        assert_eq!(heard.tail, "At nine o'clock, mission control in Houston");
        assert_eq!(heard.until, 23.0);
    }

    // The property Nova's dictation is built on: a full stop heard at a pause
    // to think, gone once the sentence went on, settles nothing. The
    // hearing made during the pause has "at." as its last words; the next,
    // with the words after the pause, hears one sentence.
    #[test]
    fn a_pause_to_think_in_mid_sentence_gets_no_full_stop() {
        let mut heard = Heard::new();
        heard.settle(look(4.5, vec![], "I have an appointment at."));
        heard.settle(look(
            11.0,
            vec![sentence(9.4, "I have an appointment at five.")],
            "With the doctor",
        ));
        assert_eq!(heard.text, "");
        heard.settle(look(
            13.0,
            vec![
                sentence(9.42, "I have an appointment at five."),
                sentence(12.1, "With the doctor."),
            ],
            "Bye",
        ));
        assert_eq!(heard.text, "I have an appointment at five.");
        assert!(!heard.words().contains("at."));
        assert!(!heard.words().contains("at. Five"));
    }

    // A sentence a hearing made at a pause ended with settles at the next,
    // which heard words after it, if it heard the sentence the same.
    #[test]
    fn a_sentence_heard_last_at_a_pause_settles_once_words_follow_it_the_same() {
        let mut heard = Heard::new();
        heard.settle(look(2.4, vec![], "Hello there."));
        heard.settle(look(4.0, vec![sentence(2.3, "Hello there.")], "How are"));
        assert_eq!(heard.text, "Hello there.");
        assert_eq!(heard.tail, "How are");
        let mut other = Heard::new();
        other.settle(look(2.4, vec![], "Hello there"));
        other.settle(look(4.0, vec![sentence(2.3, "Hello there.")], "How are"));
        assert_eq!(other.text, "");
    }

    // Measured on a broadcast: hearing after hearing wrote "Mission Control"
    // and "mission control" by turns, and nothing settled for 20 seconds.
    #[test]
    fn hearings_that_differ_in_capitals_or_commas_agree_on_the_newer_words() {
        let mut heard = Heard::new();
        heard.settle(look(
            9.0,
            vec![],
            "Mission Control in Houston lost contact, with our Space Shuttle. A short",
        ));
        heard.settle(look(
            11.0,
            vec![sentence(
                8.0,
                "mission control in Houston lost contact with our space shuttle.",
            )],
            "A short time later",
        ));
        assert_eq!(
            heard.text,
            "mission control in Houston lost contact with our space shuttle."
        );
    }

    #[test]
    fn a_full_stop_one_hearing_put_at_a_pause_settles_nothing_if_the_next_disagrees() {
        let mut heard = Heard::new();
        heard.settle(look(
            9.0,
            vec![sentence(4.1, "I have an appointment at.")],
            "Five.",
        ));
        heard.settle(look(
            11.0,
            vec![],
            "I have an appointment at five. With the doctor",
        ));
        assert_eq!(heard.text, "");
        assert_eq!(heard.from, 0.0);
    }

    #[test]
    fn an_abbreviation_is_not_a_sentences_end() {
        let mut heard = Heard::new();
        let dr = look(9.0, vec![sentence(3.0, "I saw Dr.")], "Smith today");
        heard.settle(dr.clone());
        heard.settle(dr);
        assert_eq!(heard.text, "");
    }

    #[test]
    fn a_comma_will_do_once_the_part_is_long_not_before() {
        let long = look(
            30.0,
            vec![piece(
                14.0,
                Kind::Soft,
                "We talked about the trip, the hotel and the flights,",
            )],
            "and then",
        );
        let mut heard = Heard::new();
        heard.settle(long.clone());
        heard.settle(long.clone());
        assert_eq!(
            heard.text,
            "We talked about the trip, the hotel and the flights,"
        );
        let mut later = Heard {
            from: 10.0,
            ..Heard::new()
        };
        later.settle(long.clone());
        later.settle(long);
        assert_eq!(later.text, "");
    }

    // What the hearing that settled a sentence heard after it is what the
    // next one, from the cut, has to agree with: the next sentence settles
    // one hearing sooner than if it waited for two new ones, and only if the
    // new start hears it the same.
    #[test]
    fn after_a_cut_the_next_hearing_agrees_with_what_the_last_heard_after_it() {
        let mut heard = Heard::new();
        heard.settle(look(6.0, vec![sentence(3.0, "One.")], "Two"));
        heard.settle(look(
            9.0,
            vec![sentence(3.0, "One."), sentence(6.2, "Two.")],
            "Three",
        ));
        assert_eq!(heard.text, "One.");
        assert_eq!(heard.from, 3.0);
        assert_eq!(heard.tail, "Two. Three");
        heard.settle(look(10.0, vec![sentence(6.3, "Two.")], "Three and"));
        assert_eq!(heard.text, "One. Two.");
        assert_eq!(heard.from, 6.3);
        // Heard otherwise from the new start, it waits.
        let mut other = Heard::new();
        other.settle(look(6.0, vec![sentence(3.0, "One.")], "Two"));
        other.settle(look(
            9.0,
            vec![sentence(3.0, "One."), sentence(6.2, "Two.")],
            "Three",
        ));
        other.settle(look(10.0, vec![sentence(6.3, "To.")], "Three and"));
        assert_eq!(other.text, "One.");
    }

    #[test]
    fn a_hearing_is_of_use_only_from_the_unsettled_start_and_newer() {
        let heard = Heard {
            from: 0.0,
            until: 20.0,
            ..Heard::new()
        };
        let newer = look(21.4, vec![], "a");
        assert!(heard.useful(0.0, &newer));
        assert!(!heard.useful(3.0, &newer));
        assert!(!heard.useful(0.0, &look(19.0, vec![], "a")));
        let settled = Heard {
            from: 21.4,
            ..Heard::new()
        };
        assert!(!settled.useful(21.4, &newer));
    }

    #[test]
    fn the_newest_hearing_heard_it_all_when_the_voice_stopped_well_before_its_end() {
        let heard = Heard {
            until: 30.0,
            ..Heard::new()
        };
        assert!(heard.heard_all(29.5));
        assert!(!heard.heard_all(29.7));
        assert!(!Heard::new().heard_all(0.0));
    }

    #[test]
    fn joins_go_on_in_lower_case_after_a_comma_and_names_keep_their_capitals() {
        assert_eq!(join("", "Hello."), "Hello.");
        assert_eq!(join("Done.", "Next one."), "Done. Next one.");
        assert_eq!(
            join(
                "At nine o'clock this morning,",
                "Mission control lost contact."
            ),
            "At nine o'clock this morning, mission control lost contact."
        );
        assert_eq!(join("I said,", "I think."), "I said, I think.");
        assert_eq!(join("Hello,", "NASA said."), "Hello, NASA said.");
        assert_eq!(join("and,", "Dr. Smith came."), "and, Dr. Smith came.");
        assert_eq!(
            join("a crew of seven,", "Lieutenant Colonel Anderson."),
            "a crew of seven, Lieutenant Colonel Anderson."
        );
        assert_eq!(join("Ciao,", "Ècco qui."), "Ciao, ècco qui.");
    }
}
