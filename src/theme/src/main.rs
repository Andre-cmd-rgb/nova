//! nova-theme: Nova's theme engine.

mod adaptive;
mod background;
mod bar;
mod color;
mod error;
mod fsutil;
mod image;
mod palette;
mod paths;
mod picker;
mod template;
mod theme;

use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use error::{Error, Result};
use palette::{parse_amount, Palette, Rgb};
use paths::Paths;

const USAGE: &str = "\
Usage: nova-theme <command> [args]

  set <theme>               apply a theme
  refresh                   render and apply the theme in use again, if Nova's
                            templates or the theme's files changed since
  list [--colors]           list the installed themes; --colors adds each one's
                            background, foreground and accent, tab-separated
  current                   print the current theme
  pick                      choose a theme in the picker
  bg list                   list the backgrounds offered for the current theme
  bg current                print the background in use
  bg set <image>            use an image as the background
  bg next                   switch to the next background
  bg pick                   choose a background in the picker
  color [--file <colors.toml>] (--all | <key> [fallback])
                            resolve palette colors, by default the current theme's
  mix <#a> <#b> <amount>    blend a toward b by a fraction (0.3) or percent (30%)
  adaptive [auto|dark|light]
                            print whether the adaptive theme is dark, light or
                            as its background is, or make it so
  palette <image> [dark|light]
                            print the palette the adaptive theme takes from an
                            image
  bar <edge> <thickness> <width>x<height> <#text> <#background>
                            for a see-through bar on that edge of a screen of
                            that size: the text color that reads on the
                            background there, and the shade behind it:
                            <#ink> <#shade> <strength>
  render <dir> <template>...
                            render templates into <dir> with <dir>/colors.toml
";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    match run(&args) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) if e.usage => {
            if !e.message.is_empty() {
                eprintln!("nova-theme: {e}");
            }
            eprint!("{USAGE}");
            ExitCode::from(2)
        }
        Err(e) => {
            eprintln!("nova-theme: {e}");
            ExitCode::FAILURE
        }
    }
}

fn run(args: &[&str]) -> Result<()> {
    match args {
        ["-h" | "--help" | "help"] => {
            print!("{USAGE}");
            Ok(())
        }
        ["mix", a, b, amount] => {
            let (Some(a), Some(b), Some(t)) = (Rgb::parse(a), Rgb::parse(b), parse_amount(amount))
            else {
                return Err(Error::usage("mix takes two #rrggbb colors and an amount"));
            };
            println!("{}", a.mix(b, t));
            Ok(())
        }
        ["render", dir, templates @ ..] => {
            let templates: Vec<PathBuf> = templates.iter().map(PathBuf::from).collect();
            theme::render_dir(Path::new(dir), &templates)
        }
        ["color", rest @ ..] => color(rest),
        _ => {
            let paths = Paths::from_env()?;
            match args {
                ["set", name] => theme::set(&paths, name),
                ["refresh"] => theme::refresh(&paths),
                ["list"] => print_lines(theme::list(&paths)),
                ["list", "--colors"] => print_lines(theme::list_colors(&paths)),
                ["current"] => print_lines(theme::current(&paths)),
                ["pick"] => theme::pick(&paths),
                ["bg", "list"] => {
                    print_lines(background::list(&paths)?.iter().map(|p| p.display()))
                }
                ["bg", "current"] => {
                    print_lines(background::current(&paths).iter().map(|p| p.display()))
                }
                ["bg", "set", image] => background::set(&paths, Path::new(image)),
                ["bg", "next"] => background::next(&paths),
                ["bg", "pick"] => background::pick(&paths),
                ["adaptive"] => theme::adaptive(&paths, None),
                ["adaptive", choice] => theme::adaptive(&paths, Some(choice)),
                ["bar", edge, thickness, screen, text, backdrop] => {
                    let asked = (|| {
                        let (width, height) = screen.split_once('x')?;
                        Some((
                            image::Edge::parse(edge)?,
                            thickness.parse::<u32>().ok()?,
                            (width.parse::<u32>().ok()?, height.parse::<u32>().ok()?),
                            Rgb::parse(text)?,
                            Rgb::parse(backdrop)?,
                        ))
                    })();
                    let Some((edge, thickness, screen, text, backdrop)) = asked else {
                        return Err(Error::usage(
                            "bar takes an edge, a thickness, a screen size and two #rrggbb colors",
                        ));
                    };
                    let ink = bar::on_background(&paths, edge, thickness, screen, text, backdrop);
                    println!("{} {} {:.2}", ink.ink, ink.shade, ink.strength);
                    Ok(())
                }
                ["palette", image, mode @ ..] if mode.len() <= 1 => {
                    let mode = match mode.first() {
                        Some(word) => Some(
                            adaptive::Mode::parse(word)
                                .ok_or_else(|| Error::usage("the mode is dark or light"))?,
                        ),
                        None => None,
                    };
                    print!("{}", theme::palette_from(&paths, Path::new(image), mode)?);
                    Ok(())
                }
                _ => Err(Error::usage("")),
            }
        }
    }
}

fn print_lines<T: std::fmt::Display>(lines: impl IntoIterator<Item = T>) -> Result<()> {
    let mut out = io::stdout().lock();
    for line in lines {
        writeln!(out, "{line}")?;
    }
    Ok(())
}

/// `color [--file <colors.toml>] (--all | <key> [fallback])`. A missing key
/// tries the fallback as a key, then prints the fallback itself.
fn color(args: &[&str]) -> Result<()> {
    let mut file = None;
    let mut all = false;
    let mut words = Vec::new();
    let mut args = args.iter();
    while let Some(&arg) = args.next() {
        match arg {
            "--file" => {
                file = Some(PathBuf::from(
                    args.next()
                        .ok_or_else(|| Error::usage("--file needs a path"))?,
                ))
            }
            "--all" => all = true,
            _ if arg.starts_with('-') => return Err(Error::usage(format!("unknown option {arg}"))),
            _ => words.push(arg),
        }
    }
    let file = match file {
        Some(file) => file,
        None => Paths::from_env()?.theme().join("colors.toml"),
    };

    let palette = Palette::load(&file)?;
    match (all, words.as_slice()) {
        (true, []) => print_lines(palette.iter().map(|(k, v)| format!("{k}\t{v}"))),
        (false, [key, fallback @ ..]) if fallback.len() <= 1 => {
            let value = palette
                .get(key)
                .or_else(|| fallback.first().map(|f| palette.get(f).unwrap_or(f)));
            match value {
                Some(value) => print_lines([value]),
                None => Err(Error::new(format!("no color named '{key}'"))),
            }
        }
        _ => Err(Error::usage(
            "color takes --all, or a key and an optional fallback",
        )),
    }
}
