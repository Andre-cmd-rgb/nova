//! The property Nova's dictation is built on, with the real model on real
//! speech: a pause to think in mid-sentence gets no full stop and no
//! capital. Pauses of three seconds (the recording's own room, its quietest
//! half second over and over) are put between words of a sentence, and the
//! recording is dictated as nova-dictationd dictates it.
//!
//! It needs the model and a recording, so it runs only when told where they
//! are, and says it was passed over otherwise:
//!
//!   NOVA_DICTATION_MODEL=~/.local/share/nova-dictation/ggml-parakeet-tdt-0.6b-v3-q8_0.bin \
//!   NOVA_DICTATION_SPEECH=<speech, raw 16 kHz mono 16-bit> \
//!     cargo test -p nova-dictation --release --test speech -- --nocapture
//!
//! (NOVA_DICTATION_LIBRARY for an engine elsewhere than whisper-cpp's;
//! SPEECH_TRACE=1 prints each hearing.) The recording is to be ordinary
//! speech, without long pauses of its own: what is dictated is measured
//! against one hearing of it all, and one hearing of a recording with long
//! pauses, or of more than a minute, leaves words out. It passed on the
//! public-domain recordings measured for dictation: the JFK sample
//! whisper.cpp ships (samples/jfk.wav), and two of the US president's
//! broadcasts on Wikimedia Commons (gb0.oga, gb1.ogg), each as raw 16 kHz
//! mono 16-bit.

use std::sync::atomic::AtomicBool;

use nova_dictation::dictation::{Dictation, Next};
use nova_dictation::engine::{Engine, Token, LIBRARY, RATE};
use nova_dictation::settle::bare;

const PAUSE: f64 = 3.0;

fn words_of(tokens: &[Token]) -> Vec<(String, i64, i64)> {
    // Whole words, with the time the first piece starts and the last ends.
    let mut words: Vec<(String, i64, i64)> = Vec::new();
    for t in tokens.iter().filter(|t| t.t0 >= 0) {
        let text = t.text.replace('\u{2581}', " ");
        match words.last_mut() {
            Some(last) if !t.word_start => {
                last.0.push_str(&text);
                last.2 = t.t1;
            }
            _ => words.push((text.trim().to_owned(), t.t0, t.t1)),
        }
    }
    words
}

fn ends_sentence(word: &str) -> bool {
    word.ends_with(['.', '!', '?'])
}

/// A number, which one hearing writes in figures and the next in words
/// ("9 o'clock", "nine o'clock"): no place to look for a pause's words.
fn number(word: &str) -> bool {
    const WORDS: [&str; 20] = [
        "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven",
        "twelve", "twenty", "thirty", "forty", "fifty", "hundred", "thousand", "million", "half",
    ];
    word.chars().any(|c| c.is_ascii_digit()) || WORDS.contains(&bare(word).as_str())
}

/// Words apart, as bare words: the edits from one to the other.
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

#[test]
fn a_pause_to_think_in_mid_sentence_gets_no_full_stop_with_the_real_model() {
    let (Some(model), Some(speech)) = (
        std::env::var_os("NOVA_DICTATION_MODEL"),
        std::env::var_os("NOVA_DICTATION_SPEECH"),
    ) else {
        eprintln!("passed over: NOVA_DICTATION_MODEL and NOVA_DICTATION_SPEECH say where the model and a recording are");
        return;
    };
    let library = std::env::var("NOVA_DICTATION_LIBRARY").unwrap_or_else(|_| LIBRARY.to_owned());
    let mut engine = Engine::load(&library, model.as_ref()).expect("the model");
    let bytes = std::fs::read(&speech).expect("the recording");
    let mut audio: Vec<i16> = bytes
        .as_chunks::<2>()
        .0
        .iter()
        .map(|&b| i16::from_le_bytes(b))
        .collect();
    // A minute at most, to its quietest 20 ms in the last ten seconds: one
    // hearing of more leaves things out (of a three-minute broadcast, a
    // whole sentence), and is no longer the words to measure against.
    if audio.len() > 60 * RATE {
        let frame = RATE / 50;
        let e = |s: &[i16]| s.iter().map(|&x| (x as f64).powi(2)).sum::<f64>();
        let end = (50 * RATE..60 * RATE - frame)
            .step_by(RATE / 1000)
            .min_by(|&a, &b| e(&audio[a..a + frame]).total_cmp(&e(&audio[b..b + frame])))
            .unwrap_or(60 * RATE);
        audio.truncate(end + frame / 2);
    }
    let stop = AtomicBool::new(false);
    let floats = |s: &[i16]| s.iter().map(|&x| x as f32 / 32768.0).collect::<Vec<_>>();

    // What one hearing of it all writes, and the gaps inside its sentences
    // where the recording falls silent between the words: a pause to think
    // comes after a word, never inside one, and the words of connected
    // speech often run into each other with no silence to put one in.
    let whole = words_of(&engine.hear(&floats(&audio), 8, &stop).expect("heard"));
    let seconds = audio.len() as f64 / RATE as f64;
    let energy =
        |s: &[i16]| s.iter().map(|&x| (x as f64).powi(2)).sum::<f64>() / s.len().max(1) as f64;
    let db = |e: f64| 10.0 * (e.max(1e-9) / (32768.0f64 * 32768.0)).log10();
    let frame = RATE / 50;
    let mut levels: Vec<f64> = audio.chunks(frame).map(|f| db(energy(f))).collect();
    levels.sort_by(f64::total_cmp);
    let speech = levels[levels.len() * 3 / 4];
    let quiet_at = |from: f64, to: f64| -> Option<usize> {
        let span = RATE * 4 / 100;
        let (a, b) = (
            (from * RATE as f64) as usize,
            ((to * RATE as f64) as usize).min(audio.len() - span),
        );
        (a..b.max(a))
            .step_by(RATE / 100)
            .min_by(|&x, &y| energy(&audio[x..x + span]).total_cmp(&energy(&audio[y..y + span])))
            .filter(|&x| db(energy(&audio[x..x + span])) <= speech - 20.0)
            .map(|x| x + span / 2)
    };
    let mut gaps = Vec::new();
    for (i, pair) in whole.windows(2).enumerate() {
        let (end, start) = (pair[0].2 as f64 / 100.0, pair[1].1 as f64 / 100.0);
        let at = (end + start) / 2.0;
        let clear = gaps
            .last()
            .is_none_or(|&(_, last, _): &(usize, f64, usize)| at - last >= 3.0);
        if !pair[0].0.ends_with([',', '.', '!', '?', ';', ':'])
            && !number(&pair[0].0)
            && !number(&pair[1].0)
            && pair[1].0.chars().next().is_some_and(char::is_lowercase)
            && at > 1.5
            && at < seconds - 1.5
            && clear
        {
            if let Some(cut) = quiet_at(end - 0.04, start + 0.04) {
                gaps.push((i, at, cut));
            }
        }
    }
    let gaps: Vec<(usize, f64, usize)> = gaps.into_iter().take(3).collect();
    assert!(
        !gaps.is_empty(),
        "no silent gap inside a sentence to pause at"
    );
    eprintln!(
        "paused at: {:?}",
        gaps.iter()
            .map(|g| format!(
                "{} {} @{:.2}",
                whole[g.0].0,
                whole[g.0 + 1].0,
                g.2 as f64 / RATE as f64
            ))
            .collect::<Vec<_>>()
    );

    // The room: the quietest half second.
    let half = RATE / 2;
    let quiet = (0..audio.len().saturating_sub(half))
        .step_by(RATE / 50)
        .min_by(|&a, &b| energy(&audio[a..a + half]).total_cmp(&energy(&audio[b..b + half])))
        .expect("a recording");
    let room = &audio[quiet..quiet + half];
    let mut paused = Vec::new();
    let mut from = 0;
    for &(_, _, cut) in &gaps {
        paused.extend_from_slice(&audio[from..cut]);
        paused.extend(room.iter().cycle().take((PAUSE * RATE as f64) as usize));
        from = cut;
    }
    paused.extend_from_slice(&audio[from..]);

    // Dictated as the daemon does, each hearing as soon as it is due.
    let mut d = Dictation::new();
    for chunk in paused.chunks(RATE / 50) {
        d.push(chunk);
        if let Some(window) = d.due() {
            let tokens = engine.hear(&d.samples(window), 4, &stop).expect("heard");
            d.heard(window, &tokens);
            if std::env::var_os("SPEECH_TRACE").is_some() {
                let heard: String = tokens
                    .iter()
                    .map(|t| t.text.replace('\u{2581}', " "))
                    .collect();
                let s = d.settled();
                eprintln!(
                    "{:6.2}-{:6.2} heard:{heard}\n        settled to {:.2}: …{}",
                    window.from,
                    window.end,
                    s.from,
                    s.text
                        .chars()
                        .rev()
                        .take(60)
                        .collect::<Vec<_>>()
                        .into_iter()
                        .rev()
                        .collect::<String>()
                );
            }
        }
    }
    let said = match d.finish() {
        Next::Words(words) => words,
        Next::Hear(window) => {
            let tokens = engine.hear(&d.samples(window), 8, &stop).expect("heard");
            match d.heard(window, &tokens) {
                Next::Words(words) => words,
                other => panic!("the end gave {other:?}"),
            }
        }
        Next::Nothing => panic!("nothing under way to wait for"),
    };
    eprintln!(
        "whole: {}",
        whole
            .iter()
            .map(|w| w.0.as_str())
            .collect::<Vec<_>>()
            .join(" ")
    );
    eprintln!("said:  {said}");

    let said: Vec<&str> = said.split_whitespace().collect();
    let bares: Vec<String> = said.iter().map(|w| bare(w)).collect();
    // Anywhere, not only at the pauses: no sentence ended that one hearing
    // of it all does not end, and the words those of one hearing, but for
    // a few (a name spelt another way, a number in figures).
    let ends = |words: &mut dyn Iterator<Item = &str>| words.filter(|w| ends_sentence(w)).count();
    assert!(
        ends(&mut said.iter().copied()) <= ends(&mut whole.iter().map(|w| w.0.as_str())),
        "more sentences than one hearing of it all makes"
    );
    let whole_bares: Vec<String> = whole
        .iter()
        .map(|w| bare(&w.0))
        .filter(|w| !w.is_empty())
        .collect();
    let said_bares: Vec<String> = bares.iter().filter(|w| !w.is_empty()).cloned().collect();
    let apart = distance(&whole_bares, &said_bares);
    assert!(
        apart <= 2.max(whole_bares.len() / 20),
        "{apart} words apart from one hearing of it all"
    );
    let whole: Vec<&str> = whole.iter().map(|w| w.0.as_str()).collect();
    for &(i, at, _) in &gaps {
        if let Err(e) = unmarked_at(&whole, &said, i) {
            panic!("the pause at {at:.2} s: {e}");
        }
    }
}

/// Whether, between the words <i> and <i + 1> of one hearing of it all
/// (<whole>), what was dictated (<said>) has no full stop and no capital:
/// looked for at that very place, as the fewest edits from one to the other
/// put it, not wherever the same two words come first.
fn unmarked_at(whole: &[&str], said: &[&str], i: usize) -> Result<(), String> {
    let (before, after) = (bare(whole[i]), bare(whole[i + 1]));
    let a: Vec<String> = whole.iter().map(|w| bare(w)).collect();
    let b: Vec<String> = said.iter().map(|w| bare(w)).collect();
    let at = aligned(&a, &b);
    let j = match (at[i], at[i + 1]) {
        (Some(j), Some(k)) if k == j + 1 => j,
        _ => return Err(format!("\"{before} {after}\" is not in the words there")),
    };
    if ends_sentence(said[j]) || said[j + 1].starts_with(char::is_uppercase) {
        return Err(format!(
            "a full stop or a capital: \"{} {}\"",
            said[j],
            said[j + 1]
        ));
    }
    Ok(())
}

/// For each of <a>'s words, the one of <b> it is where the fewest edits
/// from one to the other keep it; none where it was left out or changed.
fn aligned(a: &[String], b: &[String]) -> Vec<Option<usize>> {
    let (n, m) = (a.len(), b.len());
    let mut d = vec![vec![0usize; m + 1]; n + 1];
    for (i, row) in d.iter_mut().enumerate() {
        row[0] = i;
    }
    for (j, cell) in d[0].iter_mut().enumerate() {
        *cell = j;
    }
    for i in 1..=n {
        for j in 1..=m {
            d[i][j] = (d[i - 1][j - 1] + usize::from(a[i - 1] != b[j - 1]))
                .min(d[i - 1][j] + 1)
                .min(d[i][j - 1] + 1);
        }
    }
    let mut out = vec![None; n];
    let (mut i, mut j) = (n, m);
    while i > 0 && j > 0 {
        if a[i - 1] == b[j - 1] && d[i][j] == d[i - 1][j - 1] {
            out[i - 1] = Some(j - 1);
            (i, j) = (i - 1, j - 1);
        } else if d[i][j] == d[i - 1][j - 1] + 1 {
            (i, j) = (i - 1, j - 1);
        } else if d[i][j] == d[i - 1][j] + 1 {
            i -= 1;
        } else {
            j -= 1;
        }
    }
    out
}

// The check itself, with no model: two words that come earlier without a
// pause do not stand in for the place of the pause.
#[test]
fn the_pause_is_checked_at_its_own_place() {
    let words = |s: &'static str| s.split_whitespace().collect::<Vec<_>>();
    let whole = words("so we went to the shop, and then we went to the park.");
    // Paused between the second "we went": words 8 and 9.
    assert_eq!((whole[8], whole[9]), ("we", "went"));
    let good = words("So we went to the shop, and then we went to the park.");
    assert_eq!(unmarked_at(&whole, &good, 8), Ok(()));
    for wrong in [
        "So we went to the shop, and then we. Went to the park.",
        "So we went to the shop, and then we Went to the park.",
        // And with an edit before it, which shifts every word after.
        "So we went to a shop, and then, we. Went to the park.",
    ] {
        assert!(unmarked_at(&whole, &words(wrong), 8).is_err(), "{wrong}");
    }
    // The two words not said there: not the earlier ones in their place.
    let without = words("So we went to the shop, and then to the park.");
    assert!(unmarked_at(&whole, &without, 8).is_err());
}
