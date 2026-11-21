//! Where the voice is in the recording: when it was last heard, and so when
//! a pause has begun.
//!
//! The recording is looked at in frames of 20 ms. A frame has voice when its
//! level (RMS, in dB below full scale, over the last 60 ms) is well over the
//! room's. The room's level is a low one of the last six seconds (the 10th
//! percentile of their levels, each over 100 ms): speech has quiet between
//! its words and phrases, a room has no voice to go under. Up to 0.6 s of
//! near silence in them (a recording's start, a broadcast's gate) does not
//! drag it down, as following the quietest frame did: that took the hiss of
//! two of the recordings measured for voice nearly all the time, so that no
//! pause was ever found. A fan that starts is the room after a few seconds.
//!
//! Sound is kept apart from voice: anything over the room by less, which
//! may be a word said softly. A pause (voice gone) is when to hear, and
//! hearing at a wrong one costs a hearing; the end of the sound is how the
//! dictation knows the words it has are all of them, and a wrong one would
//! lose words, so it is the more sensitive.
//!
//! Pauses are what the dictation looks for: hearing the recording as a
//! pause begins gives Parakeet the end of a phrase with the room after it,
//! never a word cut in two. Nothing here decides a word: a frame taken for
//! voice that was not costs a hearing, never text.

use std::collections::VecDeque;

/// Samples a second.
const RATE: usize = crate::engine::RATE;
/// A frame: 20 ms.
const FRAME: usize = RATE / 50;
/// How far over the room a frame is to have voice.
const OVER_ROOM_DB: f64 = 10.0;
/// And never under this, however quiet the room: a microphone's own hiss.
const QUIETEST_VOICE_DB: f64 = -55.0;
/// The room's level before the first frame: a quiet one, as if the six
/// seconds before it had been heard, so that a voice from the first frame
/// on is a voice (and a louder room, for those six seconds). Erring toward
/// voice is what keeps words: the end of the voice is how the dictation
/// knows the words it has are all of them.
const ROOM_START_DB: f64 = -60.0;
/// The frames the room's level is taken from (six seconds), the frames
/// each of their levels is over (100 ms), and how low among them it is.
const ROOM_FRAMES: usize = 300;
const ROOM_SMOOTH: usize = 5;
const ROOM_PERCENTILE: f64 = 0.1;
/// The frames a frame's own level is over (60 ms).
const VOICE_SMOOTH: usize = 3;
/// How far over the room, and over what, a frame is to have sound.
const OVER_ROOM_SOUND_DB: f64 = 5.0;
const QUIETEST_SOUND_DB: f64 = -62.0;

#[derive(Debug, Clone)]
pub struct Voice {
    /// Samples of the frame under way.
    partial: Vec<i16>,
    /// Frames looked at.
    frames: usize,
    /// The mean square of the last frames, newest last.
    energies: VecDeque<f64>,
    /// The levels the room's is taken from, newest last.
    levels: VecDeque<f64>,
    /// For finding a low one among them.
    sorted: Vec<f64>,
    /// The end of the last frame with voice, and with sound, in frames;
    /// none yet.
    last_voice: Option<usize>,
    last_sound: Option<usize>,
    /// Each frame's, whether it had voice, and sound: 30 000 for ten minutes.
    voiced: Vec<bool>,
    sounded: Vec<bool>,
}

impl Default for Voice {
    fn default() -> Voice {
        Voice::new()
    }
}

/// A mean square's level, in dB below full scale.
fn db(energy: f64) -> f64 {
    let rms = energy.sqrt() / 32768.0;
    if rms <= 0.0 {
        -120.0
    } else {
        20.0 * rms.log10()
    }
}

impl Voice {
    pub fn new() -> Voice {
        Voice {
            partial: Vec::with_capacity(FRAME),
            frames: 0,
            energies: VecDeque::with_capacity(ROOM_SMOOTH),
            levels: std::iter::repeat_n(ROOM_START_DB, ROOM_FRAMES).collect(),
            sorted: Vec::with_capacity(ROOM_FRAMES),
            last_voice: None,
            last_sound: None,
            voiced: Vec::new(),
            sounded: Vec::new(),
        }
    }

    /// Looks at the next samples of the recording.
    pub fn push(&mut self, mut samples: &[i16]) {
        while !samples.is_empty() {
            let take = (FRAME - self.partial.len()).min(samples.len());
            self.partial.extend_from_slice(&samples[..take]);
            samples = &samples[take..];
            if self.partial.len() == FRAME {
                let energy = self
                    .partial
                    .iter()
                    .map(|&s| (s as f64) * (s as f64))
                    .sum::<f64>()
                    / FRAME as f64;
                self.partial.clear();
                self.frame(energy);
            }
        }
    }

    /// The mean square of the newest <n> frames, in dB.
    fn over_last(&self, n: usize) -> f64 {
        let n = n.min(self.energies.len());
        db(self.energies.iter().rev().take(n).sum::<f64>() / n as f64)
    }

    fn frame(&mut self, energy: f64) {
        if self.energies.len() == ROOM_SMOOTH {
            self.energies.pop_front();
        }
        self.energies.push_back(energy);
        self.levels.pop_front();
        self.levels.push_back(self.over_last(ROOM_SMOOTH));
        self.sorted.clear();
        self.sorted.extend(self.levels.iter().copied());
        let at = (ROOM_FRAMES as f64 * ROOM_PERCENTILE) as usize;
        let room = *self.sorted.select_nth_unstable_by(at, f64::total_cmp).1;
        self.frames += 1;
        let level = self.over_last(VOICE_SMOOTH);
        let voiced = level > (room + OVER_ROOM_DB).max(QUIETEST_VOICE_DB);
        if voiced {
            self.last_voice = Some(self.frames);
        }
        let sounded = level > (room + OVER_ROOM_SOUND_DB).max(QUIETEST_SOUND_DB);
        if sounded {
            self.last_sound = Some(self.frames);
        }
        self.voiced.push(voiced);
        self.sounded.push(sounded);
    }

    /// The second of the recording the voice was last heard at, the end of
    /// its frame; none if it has not been heard yet.
    pub fn voice_at(&self) -> Option<f64> {
        self.last_voice.map(|f| (f * FRAME) as f64 / RATE as f64)
    }

    /// The second of the recording anything over the room was last heard
    /// at (voice, or what may be a word said softly); none if nothing was.
    pub fn sound_at(&self) -> Option<f64> {
        self.last_sound.map(|f| (f * FRAME) as f64 / RATE as f64)
    }

    /// The frames wholly between two seconds of the recording.
    fn frames_between(&self, from: f64, to: f64) -> std::ops::Range<usize> {
        let first = (from.max(0.0) * 50.0).ceil() as usize;
        let end = ((to.max(0.0) * 50.0).floor() as usize).min(self.voiced.len());
        first.min(end)..end
    }

    /// The longest the voice was heard without a break between two seconds
    /// of the recording, in seconds.
    pub fn longest_voice(&self, from: f64, to: f64) -> f64 {
        let (mut longest, mut run) = (0, 0);
        for &voiced in &self.voiced[self.frames_between(from, to)] {
            run = if voiced { run + 1 } else { 0 };
            longest = longest.max(run);
        }
        longest as f64 / 50.0
    }

    /// Where the voice was first heard between two seconds of the recording.
    pub fn first_voice(&self, from: f64, to: f64) -> Option<f64> {
        let frames = self.frames_between(from, to);
        let start = frames.start;
        self.voiced[frames]
            .iter()
            .position(|&v| v)
            .map(|i| (start + i) as f64 / 50.0)
    }

    /// The stretches with no sound at all wholly between two seconds of the
    /// recording, and longer than <longer> seconds: (start, end) in seconds.
    pub fn silences(&self, from: f64, to: f64, longer: f64) -> Vec<(f64, f64)> {
        let frames = self.frames_between(from, to);
        let mut out = Vec::new();
        let mut start = None;
        for i in frames.clone().chain([frames.end]) {
            let quiet = i < frames.end && !self.sounded[i];
            match (quiet, start) {
                (true, None) => start = Some(i),
                (false, Some(s)) => {
                    if (i - s) as f64 / 50.0 > longer {
                        out.push((s as f64 / 50.0, i as f64 / 50.0));
                    }
                    start = None;
                }
                _ => {}
            }
        }
        out
    }

    /// How long the recording has been without voice, in seconds, up to its
    /// last whole frame: all of it, if no voice was heard yet.
    pub fn quiet_for(&self) -> f64 {
        let since = self.last_voice.unwrap_or(0);
        ((self.frames - since) * FRAME) as f64 / RATE as f64
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    /// <seconds> of a tone at <db> dBFS (RMS), with a little noise, as test
    /// speech; -120 for silence.
    pub fn sound(seconds: f64, db: f64) -> Vec<i16> {
        let n = (seconds * RATE as f64) as usize;
        if db <= -120.0 {
            return vec![0; n];
        }
        let amplitude = 10f64.powf(db / 20.0) * 32768.0 * std::f64::consts::SQRT_2;
        let mut seed = 0x2545_f491_u32;
        (0..n)
            .map(|i| {
                seed ^= seed << 13;
                seed ^= seed >> 17;
                seed ^= seed << 5;
                let wobble = (seed % 16) as f64 - 8.0;
                let t = i as f64 / RATE as f64;
                (amplitude * (2.0 * std::f64::consts::PI * 220.0 * t).sin() + wobble)
                    .clamp(-32768.0, 32767.0) as i16
            })
            .collect()
    }

    #[test]
    fn a_voice_over_a_quiet_room_is_heard_and_its_end_found() {
        let mut voice = Voice::new();
        voice.push(&sound(0.5, -60.0));
        assert_eq!(voice.voice_at(), None);
        assert!((voice.quiet_for() - 0.5).abs() < 0.021);
        voice.push(&sound(1.0, -25.0));
        voice.push(&sound(0.4, -60.0));
        // Its end is found within the 60 ms a frame's level is taken over.
        let at = voice.voice_at().unwrap();
        assert!((1.5..1.55).contains(&at), "voice last at {at}");
        assert!((voice.quiet_for() - 0.4).abs() < 0.05);
    }

    #[test]
    fn a_louder_room_is_taken_in_within_seconds_and_a_voice_over_it_still_heard() {
        let mut voice = Voice::new();
        voice.push(&sound(0.5, -65.0));
        // A fan starts: voice to the detector for a few seconds, then the room.
        voice.push(&sound(10.0, -45.0));
        assert!(voice.quiet_for() > 3.0, "the fan is the room by now");
        voice.push(&sound(0.6, -20.0));
        voice.push(&sound(0.3, -45.0));
        let at = voice.voice_at().unwrap();
        assert!((11.1..11.15).contains(&at), "voice last at {at}");
    }

    #[test]
    fn samples_in_any_slices_make_the_same_frames() {
        let speech: Vec<i16> = [sound(0.3, -60.0), sound(0.7, -20.0), sound(0.5, -60.0)].concat();
        let mut whole = Voice::new();
        whole.push(&speech);
        let mut bits = Voice::new();
        for chunk in speech.chunks(97) {
            bits.push(chunk);
        }
        assert_eq!(whole.voice_at(), bits.voice_at());
        assert_eq!(whole.quiet_for(), bits.quiet_for());
    }

    #[test]
    fn hiss_under_the_quietest_voice_is_never_voice() {
        let mut voice = Voice::new();
        voice.push(&sound(1.0, -120.0));
        voice.push(&sound(1.0, -58.0));
        assert_eq!(voice.voice_at(), None);
    }

    // Two of the recordings measured have a moment of near silence (a
    // broadcast's gate); following the quietest frame down took their hiss
    // for voice from then on, and no pause was found.
    #[test]
    fn a_moment_of_near_silence_does_not_make_the_hiss_voice() {
        let mut voice = Voice::new();
        voice.push(&sound(1.0, -50.0));
        voice.push(&sound(0.1, -120.0));
        voice.push(&sound(1.0, -30.0));
        voice.push(&sound(0.1, -120.0));
        voice.push(&sound(1.0, -30.0));
        voice.push(&sound(0.8, -52.0));
        let at = voice.voice_at().unwrap();
        assert!((3.2..3.25).contains(&at), "voice last at {at}");
        assert!(voice.quiet_for() > 0.7);
    }

    #[test]
    fn speech_from_the_first_frame_is_voice() {
        let mut voice = Voice::new();
        voice.push(&sound(1.0, -30.0));
        voice.push(&sound(0.6, -62.0));
        let at = voice.voice_at().unwrap();
        assert!((1.0..1.05).contains(&at), "voice last at {at}");
    }

    #[test]
    fn a_word_said_softly_is_sound_though_not_voice() {
        let mut voice = Voice::new();
        voice.push(&sound(1.0, -62.0));
        voice.push(&sound(1.0, -25.0));
        voice.push(&sound(0.6, -62.0));
        voice.push(&sound(0.4, -54.0));
        voice.push(&sound(0.6, -62.0));
        let (v, s) = (voice.voice_at().unwrap(), voice.sound_at().unwrap());
        assert!((2.0..2.05).contains(&v), "voice last at {v}");
        assert!((3.0..3.05).contains(&s), "sound last at {s}");
    }
}
