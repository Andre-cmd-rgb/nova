//! One dictation, from the press to its words: the recording as it comes,
//! when to hear it while it is said, and what is left to hear at the end.
//!
//! The engine is not here: this says which part of the recording to hear
//! (a `Window`) and takes in what was heard, so that it is the same whether
//! the daemon runs Parakeet on its engine thread or a test hands it words.
//!
//! When to hear: as a pause begins (half a second without voice, after
//! voice), or after three seconds of voice with no such pause, from where the
//! text not yet settled starts. Hearing it at a pause gives Parakeet the end
//! of a phrase and the room after it, never a word cut in two (cut there, the
//! model makes up an ending); and the hearing made as the voice stops is
//! often the whole of the dictation, done by the time the key is let go.
//! settle.rs says what a hearing settles.
//!
//! And, voice or not, once the part not yet settled is UNSETTLED long as
//! heard: sound that is never voice (a room's, minutes of it after the last
//! sentence) is heard while it lasts, and settles by force, rather than all
//! at the end. No hearing, while it is said or at the end, is handed more
//! than LONGEST_HEARING: one whose hearings all failed, or whose engine is
//! slower than the speech, has its end heard in parts, each settled before
//! the next.

use crate::engine::{Token, RATE};
use crate::look::{self, Kind, Look};
use crate::settle::{self, Heard};
use crate::voice::Voice;

/// The longest a dictation runs: the shell finishes it at ten minutes, and
/// the recording stops growing a little after, whatever happens.
pub const MAX_SECONDS: f64 = 610.0;
/// The quiet after voice that is a pause worth hearing at.
pub const PAUSE: f64 = 0.5;
/// Voice for this long since the last hearing, with no pause, is heard anyway.
pub const STRIDE: f64 = 3.0;
/// A gap between two words this long, with the voice heard through this
/// much of it without a break, is speech Parakeet skipped.
const HOLE_GAP: f64 = 0.4;
const HOLE_VOICE: f64 = 0.3;
/// Less than this is not heard: not a word yet.
pub const SHORTEST: f64 = 1.0 / 3.0;
/// A silence longer than this is heard shortened to it, the middle left
/// out (see Dictation::kept).
pub const LONGEST_SILENCE: f64 = 0.6;
/// The most the part not yet settled is heard for, in seconds as heard (long
/// silences shortened, see Dictation::kept). Where hearings never agree (a
/// television or music behind the voice, speech-like noise), nothing settles
/// and every hearing heard all of it again: on 180 s of babble, 31 hearings
/// heard 1553 s and took 1051 s of CPU, the last ones 15 to 21 s each, and
/// the end of a ten-minute one would outlast the shell's wait. Past it, the
/// oldest part is settled by force (Dictation::force).
pub const UNSETTLED: f64 = 45.0;
/// The newest seconds of a hearing, as heard, that are never settled by
/// force: the words being said, with what follows a pause to think in them.
pub const UNSETTLED_KEPT: f64 = 15.0;
/// What a settling by force takes off the part not yet settled, at least.
const UNSETTLED_FREED: f64 = 5.0;
/// The most one hearing is ever handed, in seconds as heard: UNSETTLED, and
/// what is recorded while a hearing at it runs, up to this. What is longer
/// is heard to here, and the rest after it (Dictation::bounded).
pub const LONGEST_HEARING: f64 = 60.0;

/// A part of the recording to hear, in seconds into it.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Window {
    pub from: f64,
    pub end: f64,
    /// The dictation's end, which someone is waiting on.
    pub last: bool,
    /// Heard as a pause began: the words of it are often all the
    /// dictation's, if the key is let go now, so it is worth all the cores.
    pub paused: bool,
}

/// What comes next.
#[derive(Debug, Clone, PartialEq)]
pub enum Next {
    /// Nothing yet.
    Nothing,
    /// The dictation's words, all of them.
    Words(String),
    /// This part is still to hear, for the end: whatever hearing is under
    /// way is of no more use, and can be stopped. An end longer than
    /// LONGEST_HEARING comes in parts, the next once this one is heard.
    Hear(Window),
}

#[derive(Debug, Default)]
pub struct Dictation {
    audio: Vec<i16>,
    voice: Voice,
    heard: Heard,
    /// The hearing under way.
    looking: Option<Window>,
    /// The end of the newest hearing started while it was said.
    looked_to: f64,
    /// Let go: the next words that are all of it are the dictation's.
    finishing: bool,
    /// Hearings made, and the seconds of recording they heard between them.
    pub hearings: usize,
    pub seconds_heard: f64,
}

impl Dictation {
    pub fn new() -> Dictation {
        Dictation::default()
    }

    /// How long the recording is, in seconds.
    pub fn seconds(&self) -> f64 {
        self.audio.len() as f64 / RATE as f64
    }

    /// The next samples of the recording (16 kHz mono, 16-bit); false once
    /// it is as long as a dictation may be, and they were not taken.
    pub fn push(&mut self, samples: &[i16]) -> bool {
        let room = (MAX_SECONDS * RATE as f64) as usize
            - self.audio.len().min((MAX_SECONDS * RATE as f64) as usize);
        let taken = &samples[..samples.len().min(room)];
        self.audio.extend_from_slice(taken);
        self.voice.push(taken);
        taken.len() == samples.len()
    }

    /// The part to hear now, while it is said, if it is time for one: after
    /// new voice, at a pause or every STRIDE; and, voice or not, every STRIDE
    /// while the part not yet settled is UNSETTLED long as heard. Never more
    /// of it than LONGEST_HEARING.
    pub fn due(&mut self) -> Option<Window> {
        if self.finishing || self.looking.is_some() {
            return None;
        }
        let now = self.seconds();
        if now - self.heard.from < 1.0 {
            return None;
        }
        let window = Window {
            from: self.heard.from,
            end: now,
            last: false,
            paused: false,
        };
        let said = self.voice.voice_at().is_some_and(|v| v > self.looked_to);
        let paused = said && self.voice.quiet_for() >= PAUSE;
        let strode = now - self.looked_to >= STRIDE;
        let long = || {
            now - window.from >= UNSETTLED
                && heard_after(&self.kept(window), window.from) >= UNSETTLED
        };
        if !(paused || (said && strode) || (strode && long())) {
            return None;
        }
        self.looked_to = now;
        let window = self.bounded(Window { paused, ..window });
        Some(self.start(window))
    }

    /// <window>, ended where it is LONGEST_HEARING long as heard, if it is
    /// longer: a hearing costs memory and time as it grows, and one of a
    /// whole ten minutes was measured failing under an 8 GiB limit, its
    /// words lost. Cut short, it hears no pause, whatever its end was.
    fn bounded(&self, window: Window) -> Window {
        let parts = self.kept(window);
        if heard_after(&parts, window.from) <= LONGEST_HEARING {
            return window;
        }
        Window {
            end: forward(&parts, LONGEST_HEARING),
            paused: false,
            ..window
        }
    }

    fn start(&mut self, window: Window) -> Window {
        self.looking = Some(window);
        self.hearings += 1;
        self.seconds_heard += self.kept(window).iter().map(|(a, b)| b - a).sum::<f64>();
        window
    }

    /// The parts of <window> that are heard, in seconds into the recording:
    /// all of it but the middle of each silence longer than LONGEST_SILENCE,
    /// which is heard that long. A pause to think, two or three seconds
    /// without a sound in mid-sentence, heard as it was, made Parakeet end
    /// the sentence there and make up a word in the quiet ("Americans. And
    /// it's to go to the polls"), or skip the words after it; heard as a
    /// short pause, the sentence goes on. Only silence goes, where there is
    /// no sound at all (voice.rs): never a word said softly. The same window
    /// always gives the same parts: the frames in it are settled once heard.
    fn kept(&self, window: Window) -> Vec<(f64, f64)> {
        let mut parts = Vec::new();
        let mut from = window.from;
        for (start, end) in self
            .voice
            .silences(window.from, window.end, LONGEST_SILENCE)
        {
            let half = LONGEST_SILENCE / 2.0;
            parts.push((from, start + half));
            from = end - half;
        }
        parts.push((from, window.end));
        parts
    }

    /// The samples of <window>, as the engine takes them (its kept parts).
    ///
    /// As recorded: no high-pass filter, gain control or noise suppression
    /// before Parakeet, as none earned its place. On three public-domain
    /// recordings, clean and with rumble 6 dB over the speech, a microphone
    /// 36 dB down, or pink noise 10 to 0 dB under the speech, an 80 Hz
    /// high-pass and an AGC (set to -20 dBFS, or dynamic) changed no word for
    /// the better that another noise seed did not take back, and RNNoise left
    /// more words wrong in the noise it is for (at 0 dB, 20 of 95 against 5).
    pub fn samples(&self, window: Window) -> Vec<f32> {
        let at = |s: f64| ((s * RATE as f64).round() as usize).min(self.audio.len());
        self.kept(window)
            .iter()
            .flat_map(|&(a, b)| &self.audio[at(a)..at(b).max(at(a))])
            .map(|&s| s as f32 / 32768.0)
            .collect()
    }

    /// <tokens>, heard in <window>'s kept parts, with times in the window
    /// as recorded (hundredths of a second from its start).
    fn unsqueezed(&self, window: Window, tokens: &[Token]) -> Vec<Token> {
        let parts = self.kept(window);
        let at = |s: f64| ((s * RATE as f64).round() as usize).min(self.audio.len());
        // Where each part starts in what was heard, in seconds, as samples()
        // cut it.
        let mut starts = Vec::with_capacity(parts.len());
        let mut heard = 0usize;
        for &(a, b) in &parts {
            starts.push(heard as f64 / RATE as f64);
            heard += at(b).max(at(a)) - at(a);
        }
        let map = |t: i64| -> i64 {
            if t < 0 {
                return t;
            }
            let s = t as f64 / 100.0;
            let i = starts
                .iter()
                .rposition(|&start| start <= s + 1e-9)
                .unwrap_or(0);
            let recorded = parts[i].0 + (s - starts[i]);
            ((recorded - window.from) * 100.0).round() as i64
        };
        tokens
            .iter()
            .map(|t| Token {
                t0: map(t.t0),
                t1: map(t.t1),
                ..t.clone()
            })
            .collect()
    }

    /// What was heard in <window>.
    pub fn heard(&mut self, window: Window, tokens: &[Token]) -> Next {
        // One that was given up on, coming back after all, is still words
        // heard; but it is no longer what the end waits for.
        let current = self.looking == Some(window);
        if current {
            self.looking = None;
        }
        let tokens = self.unsqueezed(window, tokens);
        let look = self.unskipped(
            look::look(&tokens, window.from, window.end),
            &tokens,
            window.from,
        );
        if window.last && window.end >= self.seconds() {
            return Next::Words(crate::settle::join(&self.heard.text, &look.text()));
        }
        if window.last {
            // A part of the end, as long as a hearing may be: what it heard
            // settles, its oldest part by force (all of it, where that finds
            // no place to cut), and the rest is heard from there.
            if !current {
                return Next::Nothing;
            }
            let (parts, from) = (self.kept(window), self.heard.from);
            if self.heard.useful(window.from, &look) {
                self.heard.settle(look.clone());
            }
            if self.heard.from == from {
                self.force(window, &parts, look.clone(), &tokens);
            }
            if self.heard.from == from {
                self.heard.force_to(&look.text(), window.end, String::new());
            }
            return self.finish();
        }
        if self.heard.useful(window.from, &look) {
            let parts = self.kept(window);
            let from = self.heard.from;
            self.heard.settle(look.clone());
            if self.heard.from == from && heard_after(&parts, from) >= UNSETTLED {
                self.force(window, &parts, look, &tokens);
            }
        }
        if self.finishing && current {
            return self.finish();
        }
        Next::Nothing
    }

    /// <look>, the hearing of <window> (its kept <parts>, its <tokens>), has
    /// settled nothing, and the part not yet settled is UNSETTLED long, as
    /// heard: its oldest part settles by force, as this hearing heard it, up
    /// to a place UNSETTLED_KEPT before its end, as heard, or earlier, and
    /// UNSETTLED_FREED after its start, or later. The place is the last that
    /// ends a sentence there; else a clause; else a word, as Parakeet writes
    /// a long stretch with no ending it can be cut at; else, where it heard
    /// no words, the latest place of all. What the newest seconds hold, a
    /// pause to think among them, is settled as before, by two hearings.
    /// Speech Parakeet skipped (unskipped) is not waited for here: in a part
    /// that long, hearings that keep disagreeing skip it again.
    fn force(&mut self, window: Window, parts: &[(f64, f64)], look: Look, tokens: &[Token]) {
        let latest = rewind(parts, UNSETTLED_KEPT);
        let fits = |at: f64| {
            at > window.from
                && at <= latest
                && heard_after(parts, at) <= UNSETTLED - UNSETTLED_FREED
        };
        let last = |kind: fn(&look::Piece) -> bool| {
            look.pieces
                .iter()
                .rposition(|piece| kind(piece) && fits(piece.at))
        };
        if let Some(i) = last(settle::sentence_end).or_else(|| last(|p| p.kind == Kind::Soft)) {
            self.heard.force(look, i + 1);
            return;
        }
        let words = words(tokens, window.from);
        let said = words.iter().take_while(|w| w.end <= latest).count();
        if said == 0 {
            // Nothing but noise before it, and never into a word.
            let at = words.first().map_or(latest, |w| latest.min(w.start));
            self.heard.force_to("", at, look.text());
            return;
        }
        let joined = |words: &[Word]| {
            words
                .iter()
                .map(|w| w.text.as_str())
                .collect::<Vec<_>>()
                .join(" ")
        };
        // In the middle of the gap after the last word, as look.rs cuts,
        // unless that is too early to free enough: then as late as the next
        // word allows.
        let at = match words.get(said) {
            Some(next) => {
                let end = words[said - 1].end;
                let middle = end + (next.start - end).clamp(0.0, 2.0 * CUT_AFTER) / 2.0;
                if heard_after(parts, middle) > UNSETTLED - UNSETTLED_FREED {
                    latest.min(next.start).max(middle)
                } else {
                    middle
                }
            }
            None => latest,
        };
        self.heard
            .force_to(&joined(&words[..said]), at, joined(&words[said..]));
    }

    /// <look>, from <from>, with nothing to settle after a place Parakeet
    /// skipped: a gap between its words where the voice went on (it does,
    /// after a long pause). The part before it is cut short of the voice, so
    /// that the next hearing, from there, hears what was skipped.
    fn unskipped(&self, mut look: Look, tokens: &[Token], from: f64) -> Look {
        let at = |t: i64| from + t as f64 / 100.0;
        let hole = tokens
            .iter()
            .filter(|t| t.t0 >= 0)
            .collect::<Vec<_>>()
            .windows(2)
            .map(|pair| (at(pair[0].t1) + 0.1, at(pair[1].t0) - 0.1))
            .find(|&(start, end)| {
                end - start >= HOLE_GAP && self.voice.longest_voice(start, end) >= HOLE_VOICE
            });
        let Some((start, end)) = hole else {
            return look;
        };
        let words_end = start - 0.1;
        let keep = look
            .pieces
            .iter()
            .take_while(|p| p.end <= words_end + 1e-6)
            .count();
        if keep < look.pieces.len() {
            let after: Vec<String> = look.pieces.drain(keep..).map(|p| p.text).collect();
            look.rest = [after.join(" "), std::mem::take(&mut look.rest)]
                .join(" ")
                .trim()
                .to_owned();
        }
        if let (Some(last), Some(voice)) =
            (look.pieces.last_mut(), self.voice.first_voice(start, end))
        {
            if words_end - last.end < 0.01 {
                last.at = last.at.min((last.end + voice) / 2.0);
            }
        }
        look
    }

    /// The hearing of <window> came to nothing: stopped, or failed.
    pub fn dropped(&mut self, window: Window) -> Next {
        if self.looking != Some(window) {
            return Next::Nothing;
        }
        self.looking = None;
        if self.finishing && !window.last {
            return self.finish();
        }
        Next::Nothing
    }

    /// Let go: its words at once, when the newest hearing heard all that was
    /// said; nothing yet, when the one under way will; else the rest to hear
    /// (its first part, if it is longer than LONGEST_HEARING).
    pub fn finish(&mut self) -> Next {
        self.finishing = true;
        let now = self.seconds();
        // Not the voice's end but the sound's, the more sensitive (voice.rs):
        // a word said softly at the end is not left out.
        match self.voice.sound_at() {
            Some(sound) if self.heard.heard_all(sound) => return Next::Words(self.heard.words()),
            Some(sound) => {
                if let Some(under_way) = self.looking {
                    if !under_way.last && under_way.end > sound + 0.4 {
                        return Next::Nothing;
                    }
                }
            }
            // No sound at all: heard anyway, unless it is too short to be a
            // word.
            None => {}
        }
        if now - self.heard.from < SHORTEST {
            return Next::Words(self.heard.words());
        }
        let window = self.bounded(Window {
            from: self.heard.from,
            end: now,
            last: true,
            paused: false,
        });
        Next::Hear(self.start(window))
    }

    /// What is settled so far.
    pub fn settled(&self) -> &Heard {
        &self.heard
    }
}

/// The furthest after a word's end a settling by force cuts the recording,
/// in seconds: as look.rs's CUT_AFTER.
const CUT_AFTER: f64 = 0.3;

/// A whole word Parakeet heard, and where it starts and ends, in seconds
/// into the recording.
struct Word {
    text: String,
    start: f64,
    end: f64,
}

/// The whole words of <tokens>, heard from <from>, with their marks.
fn words(tokens: &[Token], from: f64) -> Vec<Word> {
    let mut words: Vec<Word> = Vec::new();
    for t in tokens.iter().filter(|t| t.t0 >= 0) {
        let piece = t.text.replace('\u{2581}', " ");
        let (start, end) = (from + t.t0 as f64 / 100.0, from + t.t1 as f64 / 100.0);
        match words.last_mut() {
            Some(last) if !t.word_start => {
                last.text.push_str(&piece);
                last.end = end;
            }
            _ if !piece.trim().is_empty() => words.push(Word {
                text: piece.trim().to_owned(),
                start,
                end,
            }),
            _ => {}
        }
    }
    words
}

/// The second of the recording <seconds>, as heard, before the end of
/// <parts>; their start if they are not that long.
fn rewind(parts: &[(f64, f64)], seconds: f64) -> f64 {
    let mut left = seconds;
    for &(a, b) in parts.iter().rev() {
        let length = (b - a).max(0.0);
        if length >= left {
            return b - left;
        }
        left -= length;
    }
    parts.first().map_or(0.0, |&(a, _)| a)
}

/// The second of the recording <seconds>, as heard, after the start of
/// <parts> (Dictation::kept); their end if they are not that long. Never in
/// the kept end of a long silence, the start of each part after the first:
/// a window that ended there would have that silence shortened at its end
/// as well, and be heard longer. The end of the part before, then.
fn forward(parts: &[(f64, f64)], seconds: f64) -> f64 {
    let mut left = seconds;
    for (i, &(a, b)) in parts.iter().enumerate() {
        let length = (b - a).max(0.0);
        if left <= length {
            if i > 0 && left < LONGEST_SILENCE / 2.0 {
                return parts[i - 1].1;
            }
            return a + left;
        }
        left -= length;
    }
    parts.last().map_or(0.0, |&(_, b)| b)
}

/// How long <parts> are, as heard, after second <at> of the recording.
fn heard_after(parts: &[(f64, f64)], at: f64) -> f64 {
    parts.iter().map(|&(a, b)| (b - a.max(at)).max(0.0)).sum()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::look::tests::token;
    use crate::voice::tests::sound;

    fn speech(seconds: f64) -> Vec<i16> {
        sound(seconds, -22.0)
    }

    fn quiet(seconds: f64) -> Vec<i16> {
        sound(seconds, -62.0)
    }

    #[test]
    fn nothing_is_heard_before_there_is_voice() {
        let mut d = Dictation::new();
        d.push(&quiet(3.0));
        assert_eq!(d.due(), None);
    }

    #[test]
    fn a_pause_after_voice_is_heard_from_the_start_and_only_once() {
        let mut d = Dictation::new();
        d.push(&quiet(0.3));
        d.push(&speech(1.5));
        assert_eq!(d.due(), None, "still speaking");
        d.push(&quiet(0.3));
        assert_eq!(d.due(), None, "not a pause yet");
        d.push(&quiet(0.3));
        let w = d.due().expect("a hearing at the pause");
        assert_eq!(w.from, 0.0);
        assert!((w.end - 2.4).abs() < 1e-9);
        assert!(!w.last);
        assert_eq!(d.due(), None, "one at a time");
        d.heard(w, &[token("▁Hello", 40, 120)]);
        d.push(&quiet(1.0));
        assert_eq!(d.due(), None, "nothing said since");
    }

    #[test]
    fn a_long_silence_is_heard_short_and_the_words_after_it_keep_their_times() {
        let mut d = Dictation::new();
        d.push(&quiet(0.2));
        d.push(&speech(1.0));
        d.push(&quiet(3.0));
        d.push(&speech(1.0));
        d.push(&quiet(0.5));
        let w = Window {
            from: 0.0,
            end: d.seconds(),
            last: false,
            paused: false,
        };
        // The silence after the first word (from 1.24 s, its sound's end)
        // is heard as 0.6 s.
        let heard = d.samples(w).len() as f64 / RATE as f64;
        assert!(
            (heard - (5.7 - (4.2 - 1.24 - LONGEST_SILENCE))).abs() < 0.03,
            "{heard}"
        );
        // A word heard 0.3 s into the second part was said at 4.2 s.
        let tokens = d.unsqueezed(w, &[token("▁Hello", 40, 100), token("▁world", 184, 264)]);
        assert_eq!((tokens[0].t0, tokens[0].t1), (40, 100));
        assert_eq!((tokens[1].t0, tokens[1].t1), (420, 500));
        // The silence is only what has no sound at all: a quiet word stays.
        let mut soft = Dictation::new();
        soft.push(&speech(1.0));
        soft.push(&quiet(1.0));
        soft.push(&sound(0.3, -54.0));
        soft.push(&quiet(1.0));
        soft.push(&speech(1.0));
        let w = Window {
            from: 0.0,
            end: soft.seconds(),
            last: false,
            paused: false,
        };
        // Two silences of about a second, each heard as 0.6 s; not one of
        // 2.3 s heard as 0.6 s (2.64 s heard in all).
        let heard = soft.samples(w).len() as f64 / RATE as f64;
        assert!((3.5..3.6).contains(&heard), "{heard}");
    }

    #[test]
    fn voice_with_no_pause_is_heard_every_few_seconds() {
        let mut d = Dictation::new();
        d.push(&speech(2.9));
        assert_eq!(d.due(), None);
        d.push(&speech(0.2));
        let w = d.due().expect("heard after three seconds of voice");
        d.dropped(w);
        d.push(&speech(2.0));
        assert_eq!(d.due(), None);
        d.push(&speech(1.1));
        assert!(d.due().is_some());
    }

    #[test]
    fn let_go_after_a_hearing_that_heard_it_all_the_words_come_at_once() {
        let mut d = Dictation::new();
        d.push(&quiet(0.2));
        d.push(&speech(1.2));
        d.push(&quiet(0.6));
        let w = d.due().unwrap();
        d.heard(
            w,
            &[
                token("▁Hello", 30, 80),
                token("▁there", 80, 130),
                token(".", 130, 130),
            ],
        );
        d.push(&quiet(0.3));
        assert_eq!(d.finish(), Next::Words("Hello there.".into()));
    }

    // The hearing at the pause heard all the voice; a word said softly
    // after it is not voice, but sound, and is heard.
    #[test]
    fn let_go_after_a_word_said_softly_it_is_heard() {
        let mut d = Dictation::new();
        d.push(&quiet(0.2));
        d.push(&speech(1.2));
        d.push(&quiet(0.6));
        let w = d.due().unwrap();
        d.heard(w, &[token("▁Hello", 30, 80), token(".", 80, 80)]);
        d.push(&sound(0.4, -54.0));
        d.push(&quiet(0.2));
        assert!(matches!(d.finish(), Next::Hear(w) if w.last && w.from == 0.0));
    }

    #[test]
    fn let_go_while_speaking_the_rest_is_heard_and_its_words_join_the_settled() {
        let mut d = Dictation::new();
        d.push(&speech(2.0));
        match d.finish() {
            Next::Hear(w) => {
                assert!(w.last);
                assert_eq!(w.from, 0.0);
                assert!((w.end - 2.0).abs() < 1e-9);
                assert_eq!(
                    d.heard(w, &[token("▁Still", 0, 50), token("▁talking", 50, 190)]),
                    Next::Words("Still talking".into())
                );
            }
            other => panic!("expected the rest to hear, got {other:?}"),
        }
    }

    #[test]
    fn let_go_while_a_hearing_that_will_hear_it_all_is_under_way_it_is_waited_for() {
        let mut d = Dictation::new();
        d.push(&speech(1.5));
        d.push(&quiet(0.6));
        let w = d.due().unwrap();
        d.push(&quiet(0.2));
        assert_eq!(d.finish(), Next::Nothing);
        assert_eq!(
            d.heard(w, &[token("▁Done", 20, 120), token(".", 120, 120)]),
            Next::Words("Done.".into())
        );
    }

    #[test]
    fn a_hearing_under_way_that_will_not_hear_it_all_gives_way_to_the_end() {
        let mut d = Dictation::new();
        d.push(&speech(1.5));
        d.push(&quiet(0.6));
        let w = d.due().unwrap();
        d.push(&speech(1.0));
        match d.finish() {
            Next::Hear(end) => {
                assert!(end.last);
                // The stopped hearing, coming back after, changes nothing.
                assert_eq!(d.dropped(w), Next::Nothing);
            }
            other => panic!("expected the rest to hear, got {other:?}"),
        }
    }

    #[test]
    fn a_failed_hearing_that_was_waited_for_leaves_the_rest_to_hear() {
        let mut d = Dictation::new();
        d.push(&speech(1.5));
        d.push(&quiet(0.6));
        let w = d.due().unwrap();
        assert_eq!(d.finish(), Next::Nothing);
        assert!(matches!(d.dropped(w), Next::Hear(end) if end.last));
    }

    #[test]
    fn silence_too_short_to_be_a_word_is_nothing_and_a_longer_one_is_still_heard() {
        let mut d = Dictation::new();
        d.push(&quiet(0.2));
        assert_eq!(d.finish(), Next::Words(String::new()));
        let mut d = Dictation::new();
        d.push(&quiet(1.0));
        assert!(matches!(d.finish(), Next::Hear(_)));
    }

    // Parakeet heard "Decisions." and then nothing until "Election season.",
    // though the voice went on in between: that part was skipped. What is
    // before it settles, cut before the voice; nothing after it does, so the
    // next hearing, from the cut, hears it again.
    #[test]
    fn nothing_settles_past_speech_parakeet_skipped_and_the_cut_is_before_it() {
        let mut d = Dictation::new();
        for part in [
            quiet(0.1),
            speech(0.8),
            quiet(0.15),
            speech(1.6),
            quiet(0.4),
            speech(1.4),
            quiet(0.3),
            speech(0.5),
            quiet(0.6),
        ] {
            d.push(&part);
        }
        let words = [
            token("▁Decisions", 10, 90),
            token(".", 90, 90),
            token("▁Election", 310, 380),
            token("▁season", 380, 440),
            token(".", 440, 440),
            token("▁And", 480, 520),
        ];
        let first = d.due().unwrap();
        d.heard(first, &words);
        d.push(&speech(1.0));
        d.push(&quiet(0.6));
        let second = d.due().unwrap();
        d.heard(second, &words);
        let heard = d.settled();
        assert_eq!(heard.text, "Decisions.");
        assert!(
            heard.from > 0.9 && heard.from < 1.05,
            "cut at {}",
            heard.from
        );
        assert_eq!(heard.tail, "Election season. And");
    }

    #[test]
    fn the_recording_stops_growing_at_the_longest_a_dictation_runs() {
        let mut d = Dictation::new();
        let minute = quiet(60.0);
        for _ in 0..10 {
            assert!(d.push(&minute));
        }
        assert!(!d.push(&minute));
        assert!((d.seconds() - MAX_SECONDS).abs() < 1e-9);
    }

    #[test]
    fn the_samples_of_a_window_are_the_recordings_between_its_ends() {
        let mut d = Dictation::new();
        d.push(&[0, 16384, -16384, 32767]);
        let w = Window {
            from: 1.0 / RATE as f64,
            end: 3.0 / RATE as f64,
            last: false,
            paused: false,
        };
        assert_eq!(d.samples(w), vec![0.5, -0.5]);
    }

    // Speech-like noise that triggers voice detection but produces no words
    // must not grow the unsettled window up to MAX_SECONDS (quadratic CPU).
    #[test]
    fn noise_that_never_settles_keeps_the_unsettled_window_bounded() {
        let mut d = Dictation::new();
        let mut max_window = 0.0f64;
        for _ in 0..180 {
            d.push(&speech(0.8));
            d.push(&quiet(0.2));
            if let Some(w) = d.due() {
                max_window = max_window.max(w.end - w.from);
                d.heard(w, &[]);
            }
        }
        assert!(
            max_window <= UNSETTLED + 5.0,
            "unsettled window grew to {max_window:.1} s (heard {:.1} s total)",
            d.seconds_heard
        );
        assert!(
            d.seconds_heard < 2500.0,
            "heard {:.1} s for 180 s of noise",
            d.seconds_heard
        );
        match d.finish() {
            Next::Hear(w) => assert!(
                w.end - w.from <= UNSETTLED + 5.0,
                "final window {:.1} s",
                w.end - w.from
            ),
            other => panic!("expected final hearing, got {other:?}"),
        }
    }

    /// How long <w> is as heard: what a hearing of it is handed.
    fn handed(d: &Dictation, w: Window) -> f64 {
        heard_after(&d.kept(w), w.from)
    }

    // After a sentence, minutes of low, uneven sound: over the room, so not
    // shortened as silence, but never voice. Nothing was heard while it
    // lasted, and the end was handed all of it at once (on an 8 GiB
    // computer, more than the engine can take). Now the part not yet settled
    // is heard once it is UNSETTLED long, voice or not, and settles by force.
    #[test]
    fn sound_that_is_never_voice_is_heard_while_it_lasts_and_no_hearing_is_long() {
        let mut d = Dictation::new();
        d.push(&quiet(0.2));
        d.push(&speech(1.2));
        d.push(&quiet(0.6));
        let first = d.due().expect("a hearing at the pause");
        let hello = [
            token("▁Hello", 30, 80),
            token("▁there", 80, 130),
            token(".", 130, 130),
        ];
        d.heard(first, &hello);
        let voice = d.voice.voice_at();
        let mut longest = handed(&d, first);
        for _ in 0..150 {
            d.push(&quiet(0.3));
            d.push(&sound(0.5, -54.0));
            if let Some(w) = d.due() {
                longest = longest.max(handed(&d, w));
                // The sentence where the window holds it; nothing in the sound.
                let tokens: &[Token] = if w.from == 0.0 { &hello } else { &[] };
                d.heard(w, tokens);
            }
        }
        assert_eq!(d.voice.voice_at(), voice, "the sound is never voice");
        assert!(d.voice.sound_at().unwrap() > 120.0, "but it is sound");
        let last = match d.finish() {
            Next::Hear(w) => w,
            other => panic!("expected the rest to hear, got {other:?}"),
        };
        longest = longest.max(handed(&d, last));
        assert!(
            longest <= LONGEST_HEARING,
            "a hearing was handed {longest:.1} s"
        );
        assert_eq!(d.heard(last, &[]), Next::Words("Hello there.".into()));
    }

    /// The words a test hears in <w>: one a second, "w<n>" at second n, from
    /// n to n + 0.4.
    fn a_word_a_second(w: Window) -> Vec<Token> {
        let first = w.from.ceil() as usize;
        let last = (w.end - 0.4).floor() as usize;
        (first..=last)
            .map(|n| {
                let t0 = ((n as f64 - w.from) * 100.0).round() as i64;
                token(&format!("▁w{n}"), t0, t0 + 40)
            })
            .collect()
    }

    // Every hearing while it is said fails, so nothing settles: none is handed
    // more than LONGEST_HEARING all the same, and the end, longer than that,
    // is heard in parts, each settled before the next, with no word lost or
    // said twice.
    #[test]
    fn hearings_that_all_fail_are_never_long_and_the_end_is_heard_in_parts() {
        let mut d = Dictation::new();
        let mut longest = 0.0f64;
        for _ in 0..150 {
            d.push(&speech(0.8));
            d.push(&quiet(0.2));
            if let Some(w) = d.due() {
                longest = longest.max(handed(&d, w));
                d.dropped(w);
            }
        }
        let (mut next, mut parts) = (d.finish(), 0);
        let words = loop {
            match next {
                Next::Hear(w) => {
                    assert!(w.last);
                    parts += 1;
                    assert!(parts < 20, "the end is heard in parts that free nothing");
                    longest = longest.max(handed(&d, w));
                    next = d.heard(w, &a_word_a_second(w));
                }
                Next::Words(words) => break words,
                Next::Nothing => panic!("nothing under way to wait for"),
            }
        };
        assert!(
            longest <= LONGEST_HEARING + 1e-9,
            "a hearing was handed {longest:.1} s"
        );
        assert!(parts > 1, "the end was heard whole");
        let said: Vec<String> = (0..150).map(|n| format!("w{n}")).collect();
        assert_eq!(words.split(' ').collect::<Vec<_>>(), said);
    }

    // An engine slower than the speech: each hearing comes back 50 s of
    // recording after it began, having freed less than that, so the part not
    // yet settled grows all the dictation. No hearing is handed more than
    // LONGEST_HEARING, and the end, let go of with one under way, has every
    // word once.
    #[test]
    fn an_engine_slower_than_the_speech_is_never_handed_a_long_hearing() {
        let mut d = Dictation::new();
        let mut longest = 0.0f64;
        let mut under_way: Option<(Window, usize)> = None;
        for second in 0..300 {
            d.push(&speech(0.8));
            d.push(&quiet(0.2));
            if let Some((w, began)) = under_way {
                if second >= began + 50 {
                    d.heard(w, &a_word_a_second(w));
                    under_way = None;
                }
            }
            if under_way.is_none() {
                if let Some(w) = d.due() {
                    longest = longest.max(handed(&d, w));
                    under_way = Some((w, second));
                }
            }
        }
        assert!(
            300.0 - d.settled().from > LONGEST_HEARING,
            "the engine kept up: settled to {:.1} s",
            d.settled().from
        );
        let mut next = d.finish();
        let words = loop {
            match next {
                Next::Hear(w) => {
                    longest = longest.max(handed(&d, w));
                    next = d.heard(w, &a_word_a_second(w));
                }
                Next::Words(words) => break words,
                Next::Nothing => panic!("nothing under way to wait for"),
            }
        };
        assert!(
            longest <= LONGEST_HEARING + 1e-9,
            "a hearing was handed {longest:.1} s"
        );
        let said: Vec<String> = (0..300).map(|n| format!("w{n}")).collect();
        assert_eq!(words.split(' ').collect::<Vec<_>>(), said);
    }

    // Where LONGEST_HEARING falls just after a long silence, in the part of
    // it that is kept: a window cut there would have the silence shortened at
    // its end too, and be handed more. It is cut before the silence instead.
    #[test]
    fn a_part_of_the_end_that_would_end_in_a_long_silence_ends_before_it() {
        let mut d = Dictation::new();
        for _ in 0..59 {
            d.push(&speech(0.8));
            d.push(&quiet(0.2));
        }
        d.push(&speech(0.6));
        d.push(&quiet(5.0));
        for _ in 0..10 {
            d.push(&speech(0.8));
            d.push(&quiet(0.2));
        }
        let w = match d.finish() {
            Next::Hear(w) => w,
            other => panic!("expected the rest to hear, got {other:?}"),
        };
        assert!(w.end < 60.0, "cut at {:.2} s, after the silence", w.end);
        let handed = handed(&d, w);
        assert!(
            (LONGEST_HEARING - 0.5..=LONGEST_HEARING).contains(&handed),
            "handed {handed:.2} s"
        );
    }

    // Oscillating first word prevents normal prefix agreement, but sentences
    // behind it still settle once the unsettled stretch reaches the bound.
    #[test]
    fn disagreeing_hearings_force_settle_at_a_sentence_and_bound_the_window() {
        let mut d = Dictation::new();
        let mut max_window = 0.0f64;
        let mut toggle = false;
        for sec in 0..120 {
            d.push(&speech(0.8));
            d.push(&quiet(0.2));
            if let Some(w) = d.due() {
                max_window = max_window.max(w.end - w.from);
                toggle = !toggle;
                // Emit one sentence every 5 s inside the window, with the first
                // word toggling between "Uh" and "Um" so normal agreement fails.
                let mut tokens = Vec::new();
                let start_s = (w.from.ceil() as usize).max(1);
                let end_s = w.end.floor() as usize;
                let mut first = true;
                let mut s = start_s;
                while s + 2 <= end_s {
                    let t0 = ((s as f64 - w.from) * 100.0).round() as i64;
                    let lead = if first {
                        first = false;
                        if toggle {
                            "▁Uh"
                        } else {
                            "▁Um"
                        }
                    } else {
                        "▁Word"
                    };
                    tokens.push(token(lead, t0, t0 + 40));
                    tokens.push(token(&format!("▁n{s}"), t0 + 50, t0 + 100));
                    tokens.push(token(".", t0 + 100, t0 + 100));
                    s += 5;
                }
                let before = d.settled().from;
                d.heard(w, &tokens);
                let after = d.settled().from;
                assert!(
                    after == before || after <= w.end - UNSETTLED_KEPT + 1e-9,
                    "settled to {after:.1} s, within the newest {UNSETTLED_KEPT} s of {:.1} s",
                    w.end
                );
            }
            let _ = sec;
        }
        assert!(
            max_window <= UNSETTLED + 5.0,
            "unsettled window grew to {max_window:.1} s"
        );
        assert!(
            d.settled().from > 50.0,
            "settled only to {:.1} s",
            d.settled().from
        );
        assert!(
            !d.settled().text.is_empty(),
            "settled text should not be empty"
        );
    }

    // Continuous unpunctuated speech (no periods or commas at all) settles at
    // whole word boundaries once the unsettled stretch reaches the bound.
    #[test]
    fn unpunctuated_speech_force_settles_at_a_word_boundary() {
        let mut d = Dictation::new();
        let mut max_window = 0.0f64;
        for _ in 0..120 {
            d.push(&speech(0.8));
            d.push(&quiet(0.2));
            if let Some(w) = d.due() {
                max_window = max_window.max(w.end - w.from);
                let mut tokens = Vec::new();
                let start_s = w.from.ceil() as usize;
                let end_s = w.end.floor() as usize;
                for s in start_s..end_s {
                    let t0 = ((s as f64 - w.from) * 100.0).round() as i64;
                    tokens.push(token("▁word", t0, t0 + 40));
                    tokens.push(token(&s.to_string(), t0 + 40, t0 + 70));
                }
                let before = d.settled().from;
                d.heard(w, &tokens);
                let after = d.settled().from;
                assert!(after == before || after <= w.end - UNSETTLED_KEPT + 1e-9);
            }
        }
        assert!(
            max_window <= UNSETTLED + 5.0,
            "unsettled window grew to {max_window:.1} s"
        );
        assert!(
            d.settled().from > 50.0,
            "settled only to {:.1} s",
            d.settled().from
        );
        // No subword split: every word in settled text is "word<n>".
        assert!(
            d.settled()
                .text
                .split_whitespace()
                .all(|w| w.starts_with("word") && w.len() > 4),
            "unexpected split in settled text: {}",
            d.settled().text
        );
    }

    // Where the one word heard is across the place a settling by force
    // would cut at, the cut is before it: never into a word.
    #[test]
    fn a_settling_by_force_never_cuts_into_a_word() {
        let mut d = Dictation::new();
        for _ in 0..80 {
            d.push(&speech(0.8));
            d.push(&quiet(0.2));
            let Some(w) = d.due() else { continue };
            // No silence long enough to be shortened: heard as recorded.
            let start = w.end - w.from - UNSETTLED_KEPT - 0.2;
            let t0 = (start * 100.0).round() as i64;
            let before = d.settled().from;
            d.heard(w, &[token("▁across", t0, t0 + 50)]);
            if d.settled().from != before {
                let at = w.from + t0 as f64 / 100.0;
                assert!(
                    (d.settled().from - at).abs() < 0.011,
                    "cut at {:.2} s, the word from {at:.2} s to {:.2} s",
                    d.settled().from,
                    at + 0.5
                );
                assert_eq!(d.settled().text, "");
                return;
            }
        }
        panic!("nothing was settled by force");
    }

    // A long silent pause to think in mid-sentence (50 s of quiet between two
    // halves of one sentence) is squeezed by kept() to < 10 s of heard audio,
    // so the bound does not fire and the pause gets no full stop.
    #[test]
    fn a_long_mid_sentence_pause_is_not_broken_by_the_unsettled_bound() {
        let mut d = Dictation::new();
        d.push(&speech(3.0));
        d.push(&quiet(0.6));
        let first = d.due().unwrap();
        d.heard(
            first,
            &[
                token("▁I", 10, 30),
                token("▁have", 40, 80),
                token("▁an", 90, 110),
                token("▁appointment", 120, 200),
                token("▁at", 210, 250),
                token(".", 250, 250),
            ],
        );
        // 50 s of silent thought: longer than UNSETTLED as recorded, but
        // heard as 0.6 s.
        d.push(&quiet(50.0));
        assert_eq!(d.due(), None);
        d.push(&speech(2.0));
        d.push(&quiet(0.6));
        let second = d.due().unwrap();
        assert_eq!(second.from, 0.0);
        // Parakeet hears the squeezed window (3.0 + 0.6 + 2.0 + 0.6 = ~6.2 s)
        // as one sentence with no full stop after "at".
        d.heard(
            second,
            &[
                token("▁I", 10, 30),
                token("▁have", 40, 80),
                token("▁an", 90, 110),
                token("▁appointment", 120, 200),
                token("▁at", 210, 250),
                token("▁five", 380, 440),
                token(".", 440, 440),
            ],
        );
        assert_eq!(
            d.settled().from,
            0.0,
            "nothing force-settled across the silence"
        );
        assert_eq!(
            d.finish(),
            Next::Words("I have an appointment at five.".into())
        );
    }
}
