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

use crate::engine::{Token, RATE};
use crate::look::{self, Look};
use crate::settle::Heard;
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
    /// way is of no more use, and can be stopped.
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

    /// The part to hear now, while it is said, if it is time for one.
    pub fn due(&mut self) -> Option<Window> {
        if self.finishing || self.looking.is_some() {
            return None;
        }
        let now = self.seconds();
        let voice = self.voice.voice_at()?;
        if now - self.heard.from < 1.0 || voice <= self.looked_to {
            return None;
        }
        let paused = self.voice.quiet_for() >= PAUSE;
        if !paused && now - self.looked_to < STRIDE {
            return None;
        }
        let window = Window {
            from: self.heard.from,
            end: now,
            last: false,
            paused,
        };
        self.looked_to = now;
        Some(self.start(window))
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
        if window.last {
            return Next::Words(crate::settle::join(&self.heard.text, &look.text()));
        }
        if self.heard.useful(window.from, &look) {
            self.heard.settle(look);
        }
        if self.finishing && current {
            return self.finish();
        }
        Next::Nothing
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
    /// said; nothing yet, when the one under way will; else the rest to hear.
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
        let window = Window {
            from: self.heard.from,
            end: now,
            last: true,
            paused: false,
        };
        Next::Hear(self.start(window))
    }

    /// What is settled so far.
    pub fn settled(&self) -> &Heard {
        &self.heard
    }
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
}
