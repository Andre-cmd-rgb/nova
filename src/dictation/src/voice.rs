//! Where the voice is in the recording: when it was last heard, and so when
//! a pause has begun.
//!
//! The recording is looked at in frames of 20 ms. A frame has voice when its
//! level (RMS, in dB below full scale) is well over the room's: the room's
//! level is the quietest the frames have been, followed down at once and up
//! slowly (3 dB a second), so that a fan that starts is taken in after a few
//! seconds, and a voice never; it starts at a quiet room's. Pauses are what the dictation looks for:
//! hearing the recording as a pause begins gives Parakeet the end of a
//! phrase with the room after it, never a word cut in two. Nothing here
//! decides a word: a frame taken for voice that was not costs a hearing,
//! never text, so it errs toward voice.

/// Samples a second.
const RATE: usize = crate::engine::RATE;
/// A frame: 20 ms.
const FRAME: usize = RATE / 50;
/// How far over the room a frame is to have voice.
const OVER_ROOM_DB: f64 = 10.0;
/// And never under this, however quiet the room: a microphone's own hiss.
const QUIETEST_VOICE_DB: f64 = -55.0;
/// The room's level before the first frame: a quiet one, so that a voice
/// from the first frame on is a voice (and a louder room voice, for a few
/// seconds).
const ROOM_START_DB: f64 = -60.0;
/// How fast the room's level follows a louder room, per frame (3 dB/s).
const ROOM_RISE_DB: f64 = 3.0 / 50.0;

#[derive(Debug, Clone)]
pub struct Voice {
    /// Samples of the frame under way.
    partial: Vec<i16>,
    /// Frames looked at.
    frames: usize,
    /// The room's level, in dBFS.
    room: f64,
    /// The end of the last frame with voice, in frames; none yet.
    last_voice: Option<usize>,
    /// Each frame's, whether it had voice: 30 000 for ten minutes.
    voiced: Vec<bool>,
}

impl Default for Voice {
    fn default() -> Voice {
        Voice::new()
    }
}

/// A frame's level, in dB below full scale.
fn level(frame: &[i16]) -> f64 {
    let energy: f64 =
        frame.iter().map(|&s| (s as f64) * (s as f64)).sum::<f64>() / frame.len() as f64;
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
            room: ROOM_START_DB,
            last_voice: None,
            voiced: Vec::new(),
        }
    }

    /// Looks at the next samples of the recording.
    pub fn push(&mut self, mut samples: &[i16]) {
        while !samples.is_empty() {
            let take = (FRAME - self.partial.len()).min(samples.len());
            self.partial.extend_from_slice(&samples[..take]);
            samples = &samples[take..];
            if self.partial.len() == FRAME {
                let db = level(&self.partial);
                self.partial.clear();
                self.frame(db);
            }
        }
    }

    fn frame(&mut self, db: f64) {
        let room = if db < self.room {
            db
        } else {
            (self.room + ROOM_RISE_DB).min(db)
        };
        self.room = room;
        self.frames += 1;
        let voiced = db > (room + OVER_ROOM_DB).max(QUIETEST_VOICE_DB);
        if voiced {
            self.last_voice = Some(self.frames);
        }
        self.voiced.push(voiced);
    }

    /// The second of the recording the voice was last heard at, the end of
    /// its frame; none if it has not been heard yet.
    pub fn voice_at(&self) -> Option<f64> {
        self.last_voice.map(|f| (f * FRAME) as f64 / RATE as f64)
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
        let at = voice.voice_at().unwrap();
        assert!((at - 1.5).abs() < 0.03, "voice last at {at}");
        assert!((voice.quiet_for() - 0.4).abs() < 0.03);
    }

    #[test]
    fn a_louder_room_is_taken_in_within_seconds_and_a_voice_over_it_still_heard() {
        let mut voice = Voice::new();
        voice.push(&sound(0.5, -65.0));
        // A fan starts: voice to the detector for a few seconds, then the room.
        voice.push(&sound(8.0, -45.0));
        assert!(voice.quiet_for() > 3.0, "the fan is the room by now");
        voice.push(&sound(0.6, -20.0));
        voice.push(&sound(0.3, -45.0));
        let at = voice.voice_at().unwrap();
        assert!((at - 9.1).abs() < 0.03, "voice last at {at}");
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
}
