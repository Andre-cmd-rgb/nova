//! What one hearing of the recording says: its words, cut where a sentence
//! (or a clause) ends and more words follow it.
//!
//! Parakeet gives SentencePiece pieces with their times. A part ends at a
//! piece ending in a full stop, a question or an exclamation mark (a
//! sentence), or in a comma or an ellipsis (soft), but only where words
//! follow it after a pause of 0.12 s or more: "U.S." and "3.5" are no ends,
//! and the last words heard, with nothing after them, are never a part (the
//! rest). The place to cut the recording at, after a part, is the middle of
//! that pause, and never more than 0.3 s after the part.

use crate::engine::Token;

/// A part of what was heard, ending a sentence or a clause, with words after it.
#[derive(Debug, Clone, PartialEq)]
pub struct Piece {
    /// Seconds into the recording where it can be cut after this part.
    pub at: f64,
    /// Where its last word ends, in seconds into the recording.
    pub end: f64,
    pub kind: Kind,
    pub text: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    /// A full stop, a question or an exclamation mark.
    Sentence,
    /// A comma or an ellipsis.
    Soft,
}

/// One hearing: of the recording from where the text not yet settled
/// starts, up to <end> seconds into it.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Look {
    pub end: f64,
    pub pieces: Vec<Piece>,
    /// The words after the last piece.
    pub rest: String,
}

/// The shortest pause after an end, in Parakeet's hundredths of a second,
/// for words after it to make it one.
const PAUSE: i64 = 12;
/// The furthest after a part's end the recording is cut, in hundredths:
/// the middle of the pause after it, up to this. A longer gap may be speech
/// Parakeet skipped (it does, after a long pause), which the next hearing,
/// starting at the cut, is to hear again.
const CUT_AFTER: i64 = 30;

/// The words of <tokens>, Parakeet's pieces heard in a part of the
/// recording that starts <from> seconds in and was heard up to <end>.
pub fn look(tokens: &[Token], from: f64, end: f64) -> Look {
    let mut pieces = Vec::new();
    let mut text = String::new();
    let mut kind: Option<Kind> = None;
    let mut after = 0;
    for token in tokens {
        if token.t0 < 0 {
            continue;
        }
        let piece = token.text.replace('\u{2581}', " ");
        if let Some(k) = kind.take() {
            if token.word_start && token.t0 - after >= PAUSE && !text.trim().is_empty() {
                pieces.push(Piece {
                    at: from + (after + (token.t0 - after).min(2 * CUT_AFTER) / 2) as f64 / 100.0,
                    end: from + after as f64 / 100.0,
                    kind: k,
                    text: text.trim().to_owned(),
                });
                text.clear();
            }
        }
        text.push_str(&piece);
        if piece.ends_with("...") || piece.ends_with('…') || piece.ends_with(',') {
            kind = Some(Kind::Soft);
            after = token.t1;
        } else if piece.ends_with(['.', '?', '!']) {
            kind = Some(Kind::Sentence);
            after = token.t1;
        }
    }
    Look {
        end,
        pieces,
        rest: text.trim().to_owned(),
    }
}

impl Look {
    /// All its words.
    pub fn text(&self) -> String {
        let mut parts: Vec<&str> = self.pieces.iter().map(|p| p.text.as_str()).collect();
        parts.push(&self.rest);
        parts.retain(|t| !t.is_empty());
        parts.join(" ")
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    /// A token as Parakeet gives it: its piece ("▁" before a word), and its
    /// times in hundredths of a second.
    pub fn token(text: &str, t0: i64, t1: i64) -> Token {
        Token {
            text: text.to_owned(),
            t0,
            t1,
            word_start: text.starts_with('\u{2581}'),
        }
    }

    // The words of the shell's old test (tests/unit/shell/dictation.bats),
    // as the awk it replaces cut them.
    fn words() -> Vec<Token> {
        vec![
            token("▁And", 10, 30),
            token("▁so", 30, 50),
            token(",", 50, 50),
            token("▁fellow", 60, 80),
            token(".", 80, 80),
            token("▁Ask", 120, 140),
            token("▁U", 140, 150),
            token(".", 150, 150),
            token("S", 152, 160),
            token(".", 160, 160),
            token("▁not", 162, 180),
        ]
    }

    #[test]
    fn a_part_ends_at_a_sentences_end_with_words_after_a_pause() {
        let look = look(&words(), 1.0, 3.0);
        // "so," has no pause after it, and "U.S." is no end: one piece, cut
        // in the middle of the pause before "Ask", 1 s in plus (0.80 + 1.20) / 2.
        assert_eq!(
            look,
            Look {
                end: 3.0,
                pieces: vec![Piece {
                    at: 2.0,
                    end: 1.8,
                    kind: Kind::Sentence,
                    text: "And so, fellow.".into()
                }],
                rest: "Ask U.S. not".into(),
            }
        );
        assert_eq!(look.text(), "And so, fellow. Ask U.S. not");
    }

    #[test]
    fn a_comma_or_an_ellipsis_before_a_pause_ends_a_soft_part() {
        let tokens = vec![
            token("▁At", 0, 10),
            token("▁nine", 10, 30),
            token(",", 30, 30),
            token("▁mission", 60, 80),
            token("▁control", 80, 100),
            token("…", 100, 100),
            token("▁lost", 130, 150),
        ];
        let look = look(&tokens, 0.0, 2.0);
        assert_eq!(look.pieces.len(), 2);
        assert_eq!(look.pieces[0].kind, Kind::Soft);
        assert_eq!(look.pieces[0].text, "At nine,");
        assert!((look.pieces[0].at - 0.45).abs() < 1e-9);
        assert_eq!(look.pieces[1].text, "mission control…");
        assert_eq!(look.rest, "lost");
    }

    // Parakeet may skip what was said after a long pause: the cut after a
    // part is then near it, and what was skipped is heard again from there.
    #[test]
    fn the_cut_after_a_long_gap_is_near_the_parts_end() {
        let tokens = vec![
            token("▁decisions", 0, 60),
            token(".", 60, 60),
            token("▁Election", 520, 580),
        ];
        let look = look(&tokens, 8.0, 14.0);
        assert!((look.pieces[0].end - 8.6).abs() < 1e-9);
        assert!((look.pieces[0].at - 8.9).abs() < 1e-9);
    }

    #[test]
    fn the_last_words_are_never_a_part_however_they_end() {
        let tokens = vec![token("▁Hello", 0, 30), token(".", 30, 30)];
        let look = look(&tokens, 0.0, 1.0);
        assert!(look.pieces.is_empty());
        assert_eq!(look.rest, "Hello.");
        assert_eq!(super::look(&[], 2.0, 2.5).text(), "");
    }
}
