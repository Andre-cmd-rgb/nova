// nova-dictationd: Nova's dictation, speech to text on this computer's CPU.
//
// `nova-dictationd <model> <recording.pcm>` hears a recording (raw 16 kHz
// mono 16-bit) as a dictation would, as fast as it can, and prints its words.

use std::sync::atomic::AtomicBool;

use nova_dictation::dictation::{Dictation, Next};
use nova_dictation::engine::{Engine, LIBRARY};

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let [model, recording] = args.as_slice() else {
        eprintln!("usage: nova-dictationd <model> <recording.pcm>");
        std::process::exit(2);
    };
    let fail = |e: String| -> ! {
        eprintln!("nova-dictationd: {e}");
        std::process::exit(1);
    };
    let mut engine = Engine::load(LIBRARY, model.as_ref()).unwrap_or_else(|e| fail(e));
    let bytes = std::fs::read(recording).unwrap_or_else(|e| fail(format!("{recording}: {e}")));
    let samples: Vec<i16> = bytes
        .as_chunks::<2>()
        .0
        .iter()
        .map(|&b| i16::from_le_bytes(b))
        .collect();
    let stop = AtomicBool::new(false);
    let mut dictation = Dictation::new();
    for chunk in samples.chunks(320) {
        dictation.push(chunk);
        if let Some(window) = dictation.due() {
            let tokens = engine
                .hear(&dictation.samples(window), 4, &stop)
                .unwrap_or_else(|e| fail(e));
            dictation.heard(window, &tokens);
        }
    }
    let words = match dictation.finish() {
        Next::Words(words) => words,
        Next::Hear(window) => {
            let tokens = engine
                .hear(&dictation.samples(window), 8, &stop)
                .unwrap_or_else(|e| fail(e));
            match dictation.heard(window, &tokens) {
                Next::Words(words) => words,
                _ => String::new(),
            }
        }
        Next::Nothing => String::new(),
    };
    println!("{words}");
}
