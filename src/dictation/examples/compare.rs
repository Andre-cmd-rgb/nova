//! Dictation's text and cost, the old way against the daemon's, on the same
//! recordings: a measuring tool, not part of Nova.
//!
//!   cargo run --release --example compare -- words <model> <recording.pcm>
//!   cargo run --release --example compare -- splice <in.pcm> <out.pcm> <second>:<pause>…
//!   cargo run --release --example compare -- run <model> <recording.pcm>[@<seconds>]…
//!
//! Recordings are raw 16 kHz mono 16-bit, as pw-record makes them. `words`
//! prints what one hearing of the whole recording heard, a word a line with
//! its time, to find where to put a pause; `splice` puts pauses in (the
//! recording's own room, its quietest half second over and over); `run`
//! dictates each recording (its first <seconds>) three ways and compares:
//!
//!   whole  one hearing of all of it: the best this model does, and what
//!          the others are measured against
//!   old    the shell's way before the daemon: a hearing every 1.5 s at
//!          most, once 4 s are unsettled, on every core, each a process of
//!          its own that loads the model (its measured cost added to each),
//!          and after a cut, two new hearings to agree
//!   new    nova-dictationd's (src/dictation.rs): hearings at pauses, on 4
//!          threads, the end on 8
//!
//! Time is simulated: the recording comes at its own pace, a hearing takes
//! as long as it really took here, and its words count from then on. The
//! key is let go as the recording ends.

use std::ffi::c_int;
use std::sync::atomic::AtomicBool;
use std::time::Instant;

use nova_dictation::dictation::{Dictation, Next, Window};
use nova_dictation::engine::{Engine, Token, LIBRARY, RATE};
use nova_dictation::look;
use nova_dictation::voice::Voice;

/// What a cold parakeet-cli costs before it hears anything: the process,
/// the model's load (149-191 ms measured), its WAV, the helper's bash.
const COLD: f64 = 0.19;
const STEP: f64 = 0.01;

#[repr(C)]
struct Rusage {
    utime: [i64; 2],
    stime: [i64; 2],
    rest: [i64; 14],
}

extern "C" {
    fn getrusage(who: c_int, usage: *mut Rusage) -> c_int;
}

/// CPU seconds this process has used, all its threads.
fn cpu() -> f64 {
    let mut r = Rusage {
        utime: [0; 2],
        stime: [0; 2],
        rest: [0; 14],
    };
    // SAFETY: a struct rusage-sized buffer.
    unsafe { getrusage(0, &mut r) };
    (r.utime[0] + r.stime[0]) as f64 + (r.utime[1] + r.stime[1]) as f64 / 1e6
}

fn read(path: &str) -> Vec<i16> {
    let bytes = std::fs::read(path).unwrap_or_else(|e| panic!("{path}: {e}"));
    bytes
        .as_chunks::<2>()
        .0
        .iter()
        .map(|&b| i16::from_le_bytes(b))
        .collect()
}

fn floats(samples: &[i16]) -> Vec<f32> {
    samples.iter().map(|&s| s as f32 / 32768.0).collect()
}

struct Cost {
    hearings: usize,
    seconds: f64,
    cpu: f64,
    /// From the key's release to the words.
    wait: f64,
}

struct Ear {
    engine: Engine,
    stop: AtomicBool,
}

impl Ear {
    /// Hears <samples>; its tokens, the wall time and the CPU time it took.
    fn hear(&mut self, samples: &[f32], threads: usize) -> (Vec<Token>, f64, f64) {
        let (c, t) = (cpu(), Instant::now());
        let tokens = self
            .engine
            .hear(samples, threads, &self.stop)
            .expect("heard");
        (tokens, t.elapsed().as_secs_f64(), cpu() - c)
    }
}

fn text(tokens: &[Token]) -> String {
    look::look(tokens, 0.0, 0.0).text()
}

fn whole(ear: &mut Ear, audio: &[i16]) -> (String, Cost) {
    let (tokens, wall, cpu) = ear.hear(&floats(audio), 8);
    let seconds = audio.len() as f64 / RATE as f64;
    (
        text(&tokens),
        Cost {
            hearings: 1,
            seconds,
            cpu,
            wait: wall,
        },
    )
}

fn new_way(ear: &mut Ear, audio: &[i16]) -> (String, Cost) {
    let mut d = Dictation::new();
    let mut pending: Option<(Window, Vec<Token>, f64)> = None;
    let (mut cost_cpu, mut pushed, mut t) = (0.0, 0usize, 0.0);
    let release = audio.len() as f64 / RATE as f64;
    while t < release {
        t += STEP;
        let upto = ((t * RATE as f64) as usize).min(audio.len());
        d.push(&audio[pushed..upto]);
        pushed = upto;
        if pending.as_ref().is_some_and(|p| t >= p.2) {
            let (w, tokens, _) = pending.take().unwrap();
            d.heard(w, &tokens);
            if trace() {
                let s = d.settled();
                eprintln!(
                    "  t {t:6.2}  heard {:6.2}-{:6.2}  settled to {:6.2}  tail: {}",
                    w.from, w.end, s.from, s.tail
                );
            }
        }
        if pending.is_none() {
            if let Some(w) = d.due() {
                let (tokens, wall, c) = ear.hear(&d.samples(w), 4);
                cost_cpu += c;
                pending = Some((w, tokens, t + wall));
            }
        }
    }
    d.push(&audio[pushed..]);
    let (words, wait) = match d.finish() {
        Next::Words(words) => (words, 0.0),
        Next::Nothing => {
            let (w, tokens, done) = pending.take().expect("a hearing waited for");
            match d.heard(w, &tokens) {
                Next::Words(words) => (words, (done - release).max(0.0)),
                other => panic!("waited for nothing: {other:?}"),
            }
        }
        Next::Hear(w) => {
            let (tokens, wall, c) = ear.hear(&d.samples(w), 8);
            cost_cpu += c;
            match d.heard(w, &tokens) {
                Next::Words(words) => (words, wall),
                other => panic!("the end gave {other:?}"),
            }
        }
    };
    let cost = Cost {
        hearings: d.hearings,
        seconds: d.seconds_heard,
        cpu: cost_cpu,
        wait,
    };
    (words, cost)
}

/// The shell's own rules at 5ec3bc0, as they were: bin/dictation's awk
/// (a part cut in the middle of the pause after it, however long) and
/// DictationModel.js's settle (the pieces of two looks in a row agree, and
/// after a cut two new looks are needed).
mod old {
    use nova_dictation::engine::Token;
    use nova_dictation::look::{Kind, Look, Piece};

    pub fn look(tokens: &[Token], from: f64, end: f64) -> Look {
        let (mut pieces, mut text, mut kind, mut after) = (Vec::new(), String::new(), None, 0);
        for token in tokens.iter().filter(|t| t.t0 >= 0) {
            let piece = token.text.replace('\u{2581}', " ");
            if let Some(k) = kind.take() {
                if token.word_start && token.t0 - after >= 12 && !text.trim().is_empty() {
                    pieces.push(Piece {
                        at: from + (after + token.t0) as f64 / 200.0,
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

    const ABBREVIATIONS: [&str; 16] = [
        "dr", "mr", "mrs", "ms", "st", "prof", "jr", "sr", "vs", "etc", "sig", "dott", "ing",
        "avv", "geom", "rag",
    ];

    #[derive(Default)]
    pub struct Heard {
        pub text: String,
        pub from: f64,
        last: Option<Look>,
        pub tail: String,
        pub until: f64,
    }

    impl Heard {
        pub fn useful(&self, from: f64, look: &Look) -> bool {
            from == self.from && look.end > self.from && look.end >= self.until
        }

        pub fn settle(&mut self, look: Look) {
            let agreed = self.last.as_ref().map_or(0, |before| {
                look.pieces
                    .iter()
                    .zip(&before.pieces)
                    .take_while(|(a, b)| a.text == b.text)
                    .count()
            });
            let long = look.end - self.from >= 25.0;
            let end = |p: &Piece| {
                let last = p.text.rsplit(' ').next().unwrap_or("");
                p.kind == Kind::Sentence
                    && !(last.ends_with('.')
                        && ABBREVIATIONS.contains(&nova_dictation::settle::bare(last).as_str()))
            };
            let keep = (0..agreed)
                .filter(|&i| end(&look.pieces[i]) || (long && look.pieces[i].kind == Kind::Soft))
                .map(|i| i + 1)
                .max()
                .unwrap_or(0);
            self.until = look.end;
            if keep == 0 {
                self.tail = look.text();
                self.last = Some(look);
                return;
            }
            let kept: Vec<&str> = look.pieces[..keep]
                .iter()
                .map(|p| p.text.as_str())
                .collect();
            self.text = nova_dictation::settle::join(&self.text, &kept.join(" "));
            self.from = look.pieces[keep - 1].at;
            self.last = None;
            self.tail = Look {
                end: look.end,
                pieces: look.pieces[keep..].to_vec(),
                rest: look.rest,
            }
            .text();
        }

        pub fn heard_all(&self, voice_at: f64) -> bool {
            self.until > 0.0 && voice_at + 0.4 < self.until
        }

        pub fn words(&self) -> String {
            nova_dictation::settle::join(&self.text, &self.tail)
        }
    }
}

fn old_way(ear: &mut Ear, audio: &[i16]) -> (String, Cost) {
    let mut heard = old::Heard::default();
    let mut voice = Voice::new();
    let mut pending: Option<(f64, look::Look, f64)> = None;
    let (mut hearings, mut seconds, mut cost_cpu) = (0, 0.0, 0.0);
    let (mut pushed, mut t, mut started, mut tick) = (0usize, 0.0, -10.0, 0.0);
    let release = audio.len() as f64 / RATE as f64;
    let window = |from: f64, end: f64| {
        floats(
            &audio[(from * RATE as f64) as usize..((end * RATE as f64) as usize).min(audio.len())],
        )
    };
    while t < release {
        t += STEP;
        let upto = ((t * RATE as f64) as usize).min(audio.len());
        voice.push(&audio[pushed..upto]);
        pushed = upto;
        if pending.as_ref().is_some_and(|p| t >= p.2) {
            let (from, look, _) = pending.take().unwrap();
            if heard.useful(from, &look) {
                heard.settle(look);
            }
        }
        // The shell's timer: every half second, a look 1.5 s after the last
        // began at the soonest, once 4 s are unsettled.
        if t - tick >= 0.5 {
            tick = t;
            if pending.is_none() && t - started >= 1.5 && t - heard.from >= 4.0 {
                started = t;
                let from = heard.from;
                let (tokens, wall, c) = ear.hear(&window(from, t), 8);
                hearings += 1;
                seconds += t - from;
                cost_cpu += c;
                pending = Some((from, old::look(&tokens, from, t), t + wall + COLD));
            }
        }
    }
    voice.push(&audio[pushed..]);
    if let Some(at) = voice.voice_at() {
        if heard.heard_all(at) {
            return (
                heard.words(),
                Cost {
                    hearings,
                    seconds,
                    cpu: cost_cpu,
                    wait: 0.0,
                },
            );
        }
    }
    let from = heard.from;
    let (tokens, wall, c) = ear.hear(&window(from, release), 8);
    let words = nova_dictation::settle::join(&heard.text, &text(&tokens));
    let cost = Cost {
        hearings: hearings + 1,
        seconds: seconds + release - from,
        cpu: cost_cpu + c,
        wait: wall + COLD,
    };
    (words, cost)
}

/// Words apart: the edits from one to the other, word by word.
fn distance(a: &[String], b: &[String]) -> usize {
    let mut row: Vec<usize> = (0..=b.len()).collect();
    for (i, wa) in a.iter().enumerate() {
        let mut prev = row[0];
        row[0] = i + 1;
        for (j, wb) in b.iter().enumerate() {
            let cur = row[j + 1];
            row[j + 1] = (prev + usize::from(wa != wb))
                .min(row[j] + 1)
                .min(row[j + 1] + 1);
            prev = cur;
        }
    }
    row[b.len()]
}

fn words(s: &str, exact: bool) -> Vec<String> {
    s.split_whitespace()
        .map(|w| {
            if exact {
                w.to_owned()
            } else {
                nova_dictation::settle::bare(w)
            }
        })
        .filter(|w| !w.is_empty())
        .collect()
}

fn run(model: &str, specs: &[String]) {
    let engine = Engine::load(LIBRARY, model.as_ref()).expect("the model");
    eprintln!("backend: {:?}", Engine::backend());
    let mut ear = Ear {
        engine,
        stop: AtomicBool::new(false),
    };
    for spec in specs {
        let (path, seconds) = match spec.split_once('@') {
            Some((p, s)) => (p, Some(s.parse::<f64>().expect("seconds"))),
            None => (spec.as_str(), None),
        };
        let mut audio = read(path);
        if let Some(s) = seconds {
            audio.truncate((s * RATE as f64) as usize);
        }
        println!("== {spec} ({:.1} s)", audio.len() as f64 / RATE as f64);
        let (reference, cost) = whole(&mut ear, &audio);
        let report = |name: &str, said: &str, cost: &Cost| {
            let (r, s) = (words(&reference, true), words(said, true));
            let (rb, sb) = (words(&reference, false), words(said, false));
            println!(
                "{name:5} hearings {:3}  heard {:6.1} s  cpu {:6.2} s  wait {:5.3} s  words off {:2}/{} ({} with marks and capitals)",
                cost.hearings,
                cost.seconds,
                cost.cpu,
                cost.wait,
                distance(&rb, &sb),
                rb.len(),
                distance(&r, &s),
            );
            println!("      {said}");
        };
        report("whole", &reference, &cost);
        let (said, cost) = old_way(&mut ear, &audio);
        report("old", &said, &cost);
        let (said, cost) = new_way(&mut ear, &audio);
        report("new", &said, &cost);
    }
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("words") => {
            let mut ear = Ear {
                engine: Engine::load(LIBRARY, args[1].as_ref()).expect("the model"),
                stop: AtomicBool::new(false),
            };
            let (tokens, _, _) = ear.hear(&floats(&read(&args[2])), 8);
            for t in tokens.iter().filter(|t| t.word_start) {
                println!("{:7.2} {}", t.t0 as f64 / 100.0, t.text.replace('\u{2581}', ""));
            }
        }
        Some("splice") => {
            let audio = read(&args[1]);
            // The room: the quietest half second, by its energy.
            let half = RATE / 2;
            let energy = |s: &[i16]| s.iter().map(|&x| (x as f64).powi(2)).sum::<f64>();
            let quiet = (0..audio.len().saturating_sub(half))
                .step_by(RATE / 50)
                .min_by(|&a, &b| energy(&audio[a..a + half]).total_cmp(&energy(&audio[b..b + half])))
                .expect("a recording");
            let room = &audio[quiet..quiet + half];
            let mut cuts: Vec<(usize, usize)> = args[3..]
                .iter()
                .map(|c| {
                    let (at, pause) = c.split_once(':').expect("<second>:<pause>");
                    let at: f64 = at.parse().unwrap();
                    let pause: f64 = pause.parse().unwrap();
                    // Snapped to the quietest 20 ms within 0.12 s: between two
                    // words, never in one.
                    let at = (at * RATE as f64) as usize;
                    let frame = RATE / 50;
                    let span = RATE * 12 / 100;
                    let at = (at.saturating_sub(span)..(at + span).min(audio.len() - frame))
                        .step_by(RATE / 1000)
                        .min_by(|&a, &b| energy(&audio[a..a + frame]).total_cmp(&energy(&audio[b..b + frame])))
                        .map(|a| a + frame / 2)
                        .unwrap_or(at);
                    (at, (pause * RATE as f64) as usize)
                })
                .collect();
            cuts.sort();
            let mut out = Vec::new();
            let mut from = 0;
            for (at, pause) in cuts {
                out.extend_from_slice(&audio[from..at]);
                out.extend(room.iter().cycle().take(pause));
                from = at;
            }
            out.extend_from_slice(&audio[from..]);
            let bytes: Vec<u8> = out.iter().flat_map(|s| s.to_le_bytes()).collect();
            std::fs::write(&args[2], bytes).expect("written");
        }
        Some("run") => run(&args[1], &args[2..]),
        _ => eprintln!("usage: compare words <model> <pcm> | splice <in> <out> <s>:<pause>… | run <model> <pcm>[@<s>]…"),
    }
}

/// COMPARE_TRACE=1: each hearing of the new way, as it comes back.
fn trace() -> bool {
    std::env::var_os("COMPARE_TRACE").is_some()
}
