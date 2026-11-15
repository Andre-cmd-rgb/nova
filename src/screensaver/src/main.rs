//! nova-screensaver-effect: a text played through effects in a terminal.
//!
//! The text comes onto a black screen in one of six ways, stays a few seconds
//! and leaves, and then the next way begins, until the program is stopped.
//! nova-screensaver-run starts it in each of the screensaver's terminals, and
//! ends it at the first key.

mod canvas;
mod color;
mod effects;
mod rng;
mod text;

use std::io::Write;
use std::process::ExitCode;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use canvas::Canvas;
use color::Rgb;
use effects::{Effect, Scene};
use rng::Rng;
use text::Text;

const USAGE: &str = "\
nova-screensaver-effect [options] <text file>

Plays the text through one effect after another, until it is stopped.

  --colors <#rrggbb>[,<#rrggbb>]  the two colors the text runs between
                                  (the theme's accent, and a second)
  --effect <name>                 only this effect
  --once                          one effect, then stop
  --fps <frames>                  frames a second, 60 unless given
  --seed <number>                 the same run every time
  --list                          the effects' names
  --frame <seconds> [--size <columns>x<rows>]
                                  print the frame that far into the effect, as
                                  plain text, and stop
";

/// Nova's own two, for a text played without a theme to take them from.
const COLORS: (Rgb, Rgb) = (Rgb(0xcb, 0xa6, 0xff), Rgb(0x12, 0xbf, 0xf4));
/// The screen stays black this long between two effects.
const PAUSE: f64 = 0.7;

struct Options {
    file: String,
    colors: (Rgb, Rgb),
    effect: Option<Effect>,
    once: bool,
    fps: f64,
    seed: Option<u64>,
    frame: Option<f64>,
    size: Option<(i32, i32)>,
}

enum Asked {
    Play(Options),
    List,
    Help,
}

fn parse(args: &[String]) -> Result<Asked, String> {
    let mut options = Options {
        file: String::new(),
        colors: COLORS,
        effect: None,
        once: false,
        fps: 60.0,
        seed: None,
        frame: None,
        size: None,
    };
    let mut files = Vec::new();
    let mut args = args.iter();
    while let Some(arg) = args.next() {
        let mut value = || args.next().ok_or_else(|| format!("{arg} needs a value"));
        match arg.as_str() {
            "-h" | "--help" => return Ok(Asked::Help),
            "--list" => return Ok(Asked::List),
            "--once" => options.once = true,
            "--colors" => options.colors = colors(value()?)?,
            "--effect" => {
                let name = value()?;
                options.effect = Some(
                    Effect::named(name)
                        .ok_or_else(|| format!("no effect named {name} (--list has them)"))?,
                );
            }
            "--fps" => {
                options.fps = value()?
                    .parse()
                    .ok()
                    .filter(|fps| (1.0..=240.0).contains(fps))
                    .ok_or("--fps takes 1 to 240")?;
            }
            "--seed" => {
                options.seed = Some(
                    value()?
                        .parse()
                        .map_err(|_| "--seed takes a whole number")?,
                )
            }
            "--frame" => {
                options.frame = Some(
                    value()?
                        .parse()
                        .ok()
                        .filter(|t: &f64| t.is_finite() && *t >= 0.0)
                        .ok_or("--frame takes seconds")?,
                );
            }
            "--size" => {
                let size = value()?;
                let parts = size
                    .split_once('x')
                    .and_then(|(cols, rows)| Some((cols.parse().ok()?, rows.parse().ok()?)));
                options.size = Some(
                    parts
                        .filter(|(cols, rows)| {
                            (1..=1000).contains(cols) && (1..=1000).contains(rows)
                        })
                        .ok_or("--size takes <columns>x<rows>")?,
                );
            }
            _ if arg.starts_with('-') && arg.len() > 1 => {
                return Err(format!("unknown option {arg}"))
            }
            _ => files.push(arg.clone()),
        }
    }
    match files.as_slice() {
        [file] => options.file = file.clone(),
        [] => return Err("which text? Give its file".into()),
        _ => return Err("one text file at a time".into()),
    }
    Ok(Asked::Play(options))
}

/// One color or two, each lit for a black screen. With one, the second is its
/// neighbour a little way round the color wheel.
fn colors(text: &str) -> Result<(Rgb, Rgb), String> {
    let bad = || format!("--colors takes #rrggbb or #rrggbb,#rrggbb, not {text}");
    let (first, second) = match text.split_once(',') {
        Some((first, second)) => (first, Some(second)),
        None => (text, None),
    };
    let first = Rgb::parse(first).ok_or_else(bad)?;
    let second = match second {
        Some(second) => Rgb::parse(second).ok_or_else(bad)?,
        None => first.turned(-50.0),
    };
    Ok((first.lit(), second.lit()))
}

/// The terminal's size in columns and rows, when standard output is one.
fn terminal_size() -> Option<(i32, i32)> {
    #[repr(C)]
    #[derive(Default)]
    struct WinSize {
        rows: u16,
        cols: u16,
        width: u16,
        height: u16,
    }
    extern "C" {
        fn ioctl(fd: i32, request: u64, ...) -> i32;
    }
    const TIOCGWINSZ: u64 = 0x5413;
    let mut size = WinSize::default();
    // SAFETY: TIOCGWINSZ writes one winsize, the struct above, through the
    // pointer, which is valid for as long as the call lasts.
    let answered = unsafe { ioctl(1, TIOCGWINSZ, &mut size as *mut WinSize) } == 0;
    (answered && size.cols > 0 && size.rows > 0)
        .then(|| (i32::from(size.cols), i32::from(size.rows)))
}

/// The cursor back and the colors as they were, when the program is stopped
/// from outside: a terminal someone tried this in is left usable.
fn restore_on_signal() {
    extern "C" {
        fn signal(signal: i32, handler: extern "C" fn(i32)) -> usize;
        fn write(fd: i32, bytes: *const std::ffi::c_void, count: usize) -> isize;
        fn _exit(status: i32) -> !;
    }
    extern "C" fn stopped(_: i32) {
        const RESTORE: &[u8] = b"\x1b[?2026l\x1b[0m\x1b[?25h\r\n";
        // SAFETY: write and _exit are async-signal-safe, and the bytes are a
        // constant.
        unsafe {
            write(1, RESTORE.as_ptr().cast(), RESTORE.len());
            _exit(0);
        }
    }
    const SIGHUP: i32 = 1;
    const SIGINT: i32 = 2;
    const SIGTERM: i32 = 15;
    for which in [SIGHUP, SIGINT, SIGTERM] {
        // SAFETY: the handler only calls async-signal-safe functions.
        unsafe { signal(which, stopped) };
    }
}

/// The effects in a new order each round, and never the same one twice in a
/// row.
struct Order {
    round: Vec<Effect>,
    last: Option<Effect>,
}

impl Order {
    fn next(&mut self, rng: &mut Rng) -> Effect {
        if self.round.is_empty() {
            self.round = Effect::ALL.to_vec();
            for i in (1..self.round.len()).rev() {
                self.round.swap(i, rng.below(i + 1));
            }
            // The round is taken from its end.
            if self.round.last().copied() == self.last {
                self.round.swap(0, Effect::ALL.len() - 1);
            }
        }
        self.last = self.round.pop();
        self.last.unwrap_or(Effect::Gather)
    }
}

fn play(options: &Options, text: &Text, rng: &mut Rng) -> std::io::Result<()> {
    let mut out = std::io::stdout().lock();
    restore_on_signal();
    out.write_all(b"\x1b[?25l\x1b[2J")?;
    let step = Duration::from_secs_f64(1.0 / options.fps);
    let mut order = Order {
        round: Vec::new(),
        last: None,
    };
    let mut bytes = String::new();
    loop {
        let effect = options.effect.unwrap_or_else(|| order.next(rng));
        let seed = rng.next();
        let (mut cols, mut rows) = terminal_size().or(options.size).unwrap_or((80, 24));
        let mut scene = Scene::new(text, cols, rows, options.colors, seed);
        let mut shown = Canvas::new(cols, rows);
        let mut next = Canvas::new(cols, rows);
        let started = Instant::now();
        let mut frames = 0u32;
        loop {
            let t = started.elapsed().as_secs_f64();
            if t > effect.length() + PAUSE {
                break;
            }
            // A terminal takes its window's size a moment after it opens, and
            // a window can change: the text is centred again, and drawn anew.
            let size = terminal_size().or(options.size).unwrap_or((80, 24));
            bytes.clear();
            if size != (cols, rows) {
                (cols, rows) = size;
                scene = Scene::new(text, cols, rows, options.colors, seed);
                shown = Canvas::new(cols, rows);
                next = Canvas::new(cols, rows);
                bytes.push_str("\x1b[2J");
            }
            next.clear();
            effect.draw(&scene, t, &mut next);
            canvas::paint(&shown, &next, &mut bytes);
            if !bytes.is_empty() {
                out.write_all(bytes.as_bytes())?;
                out.flush()?;
            }
            std::mem::swap(&mut shown, &mut next);
            // To the next frame's time; one that is already past is skipped.
            frames = frames.max((started.elapsed().as_secs_f64() / step.as_secs_f64()) as u32) + 1;
            std::thread::sleep((step * frames).saturating_sub(started.elapsed()));
        }
        if options.once {
            return out.write_all(b"\x1b[0m\x1b[?25h");
        }
    }
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let options = match parse(&args) {
        Ok(Asked::Play(options)) => options,
        Ok(Asked::List) => {
            for effect in Effect::ALL {
                println!("{}", effect.name());
            }
            return ExitCode::SUCCESS;
        }
        Ok(Asked::Help) => {
            print!("{USAGE}");
            return ExitCode::SUCCESS;
        }
        Err(problem) => {
            eprintln!("nova-screensaver-effect: {problem}\n\n{USAGE}");
            return ExitCode::from(2);
        }
    };
    let text = match std::fs::read_to_string(&options.file) {
        Ok(source) => Text::parse(&source),
        Err(problem) => {
            eprintln!("nova-screensaver-effect: {}: {problem}", options.file);
            return ExitCode::FAILURE;
        }
    };
    if text.glyphs.is_empty() {
        eprintln!(
            "nova-screensaver-effect: {}: nothing in it to show",
            options.file
        );
        return ExitCode::FAILURE;
    }
    let clock = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |now| now.as_nanos() as u64);
    let mut rng = Rng::new(
        options
            .seed
            .unwrap_or(clock ^ (u64::from(std::process::id()) << 32)),
    );

    if let Some(t) = options.frame {
        let effect = options
            .effect
            .unwrap_or(Effect::ALL[rng.below(Effect::ALL.len())]);
        let (cols, rows) = options.size.unwrap_or((80, 24));
        let scene = Scene::new(&text, cols, rows, options.colors, rng.next());
        let mut canvas = Canvas::new(cols, rows);
        effect.draw(&scene, t, &mut canvas);
        print!("{}", canvas.text());
        return ExitCode::SUCCESS;
    }
    // A terminal that closes takes the pipe with it: that is the end, not an
    // error.
    let _ = play(&options, &text, &mut rng);
    ExitCode::SUCCESS
}

#[cfg(test)]
mod tests {
    use super::*;

    fn words(line: &str) -> Vec<String> {
        line.split_whitespace().map(String::from).collect()
    }

    fn options(line: &str) -> Options {
        match parse(&words(line)) {
            Ok(Asked::Play(options)) => options,
            _ => panic!("{line} does not play"),
        }
    }

    #[test]
    fn the_text_file_and_the_defaults() {
        let options = options("words.txt");
        assert_eq!(options.file, "words.txt");
        assert_eq!(options.colors, COLORS);
        assert_eq!(options.fps, 60.0);
        assert!(
            options.effect.is_none()
                && !options.once
                && options.seed.is_none()
                && options.frame.is_none()
        );
    }

    #[test]
    fn every_option_is_read() {
        let options = options("--effect rain --once --fps 30 --seed 7 --frame 2.5 --size 100x30 --colors #ff0000,#0000ff t");
        assert_eq!(options.effect, Some(Effect::Rain));
        assert!(options.once);
        assert_eq!(
            (options.fps, options.seed, options.frame, options.size),
            (30.0, Some(7), Some(2.5), Some((100, 30)))
        );
        assert_eq!(options.colors, (Rgb(255, 64, 64), Rgb(64, 64, 255)));
    }

    #[test]
    fn one_color_brings_a_second_from_beside_it() {
        let (first, second) = colors("#ff0000").unwrap();
        assert_eq!(first, Rgb(255, 64, 64));
        assert_ne!(second, first);
        assert!(
            second.0 == 255 && second.2 > second.1,
            "{second:?} leans to magenta"
        );
    }

    #[test]
    fn what_cannot_be_meant_is_refused() {
        for line in [
            "",
            "a b",
            "--effect beams t",
            "--fps 0 t",
            "--fps many t",
            "--seed x t",
            "--frame -1 t",
            "--size 0x10 t",
            "--size wide t",
            "--colors red t",
            "--colors #ff0000,blue t",
            "--loud t",
            "--effect",
        ] {
            assert!(parse(&words(line)).is_err(), "{line} was taken");
        }
        assert!(matches!(parse(&words("--list")), Ok(Asked::List)));
        assert!(matches!(parse(&words("t --help")), Ok(Asked::Help)));
    }

    #[test]
    fn a_round_plays_every_effect_and_never_one_twice_in_a_row() {
        let mut rng = Rng::new(11);
        let mut order = Order {
            round: Vec::new(),
            last: None,
        };
        let played: Vec<Effect> = (0..600).map(|_| order.next(&mut rng)).collect();
        assert!(played.windows(2).all(|pair| pair[0] != pair[1]));
        for round in played.chunks(Effect::ALL.len()) {
            for effect in Effect::ALL {
                assert!(round.contains(&effect));
            }
        }
    }
}
