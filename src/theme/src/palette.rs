//! A theme's colors.toml, plus every shade Nova derives from it.
//!
//! This is the one palette parser: templates, terminal escape sequences, GTK and
//! the greeter all resolve colors here, so they agree on every derived shade.

use std::collections::BTreeMap;
use std::fmt;
use std::fs;
use std::path::Path;

use crate::error::{Context, Result};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Rgb(pub u8, pub u8, pub u8);

impl Rgb {
    /// Parses exactly `#rrggbb`, in either case.
    pub fn parse(s: &str) -> Option<Rgb> {
        let hex = s.strip_prefix('#')?;
        if hex.len() != 6 || !hex.bytes().all(|b| b.is_ascii_hexdigit()) {
            return None;
        }
        let channel = |i: usize| u8::from_str_radix(&hex[i..i + 2], 16).ok();
        Some(Rgb(channel(0)?, channel(2)?, channel(4)?))
    }

    /// Blends `self` toward `other` by `t` (0 keeps self, 1 gives other),
    /// rounding half up.
    pub fn mix(self, other: Rgb, t: f64) -> Rgb {
        let t = t.clamp(0.0, 1.0);
        let blend = |a: u8, b: u8| (f64::from(a) * (1.0 - t) + f64::from(b) * t + 0.5) as u8;
        Rgb(
            blend(self.0, other.0),
            blend(self.1, other.1),
            blend(self.2, other.2),
        )
    }

    /// `r,g,b` in decimal, for `rgba(r,g,b,a)` in templates.
    pub fn decimal(self) -> String {
        format!("{},{},{}", self.0, self.1, self.2)
    }

    fn brightness(self) -> u16 {
        u16::from(self.0) + u16::from(self.1) + u16::from(self.2)
    }
}

impl fmt::Display for Rgb {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "#{:02x}{:02x}{:02x}", self.0, self.1, self.2)
    }
}

/// A blend amount: a percentage (`30%`) or a fraction (`0.3`). A bare number
/// above 1 is read as a percentage.
pub fn parse_amount(s: &str) -> Option<f64> {
    let t = match s.strip_suffix('%') {
        Some(percent) => percent.parse::<f64>().ok()? / 100.0,
        None => {
            let value = s.parse::<f64>().ok()?;
            if value > 1.0 {
                value / 100.0
            } else {
                value
            }
        }
    };
    t.is_finite().then(|| t.clamp(0.0, 1.0))
}

const WHITE: Rgb = Rgb(0xff, 0xff, 0xff);
const BLACK: Rgb = Rgb(0, 0, 0);

/// Terminal palette order: 0-7 normal, 8-15 bright.
const ANSI: [&str; 16] = [
    "background",
    "red",
    "green",
    "yellow",
    "blue",
    "magenta",
    "cyan",
    "foreground",
    "muted",
    "bright_red",
    "bright_green",
    "bright_yellow",
    "bright_blue",
    "bright_magenta",
    "bright_cyan",
    "bright_foreground",
];

pub struct Palette {
    colors: BTreeMap<String, String>,
}

impl Palette {
    pub fn load(path: &Path) -> Result<Palette> {
        let text = fs::read_to_string(path).context(path.display())?;
        let (colors, skipped) = parse(&text);
        for key in skipped {
            eprintln!(
                "nova-theme: {}: skipping unsupported entry '{key}'",
                path.display()
            );
        }
        Ok(Palette::derive(colors))
    }

    pub fn get(&self, key: &str) -> Option<&str> {
        self.colors.get(key).map(String::as_str)
    }

    pub fn rgb(&self, key: &str) -> Option<Rgb> {
        self.get(key).and_then(Rgb::parse)
    }

    /// Every resolved key and value, sorted by key.
    pub fn iter(&self) -> impl Iterator<Item = (&str, &str)> {
        self.colors.iter().map(|(k, v)| (k.as_str(), v.as_str()))
    }

    #[cfg(test)]
    pub fn from_text(text: &str) -> Palette {
        Palette::derive(parse(text).0)
    }

    fn derive(colors: BTreeMap<String, String>) -> Palette {
        let mut p = Palette { colors };
        let bg = p.get("background").unwrap_or("#000000").to_owned();
        let fg = p.get("foreground").unwrap_or("#ffffff").to_owned();
        p.set("background", &bg);
        p.set("foreground", &fg);

        p.default("light_foreground", &fg);
        p.default("bright_foreground", &fg);
        p.default("dark_foreground", &mix(&fg, Rgb::parse(&bg), 0.4));
        p.default("muted", &p.value("dark_foreground"));
        let accent = p.get("blue").unwrap_or(&fg).to_owned();
        p.default("accent", &accent);
        p.default("selection", &mix(&bg, Rgb::parse(&fg), 0.25));
        p.default("selection_background", &p.value("selection"));
        p.default("selection_foreground", &p.value("bright_foreground"));
        p.set("cursor", &p.value("bright_foreground"));
        p.default("dark_background", &mix(&bg, Some(BLACK), 0.25));
        p.default("darker_background", &mix(&bg, Some(BLACK), 0.5));
        p.default("lighter_background", &mix(&bg, Rgb::parse(&fg), 0.15));

        for name in ["red", "yellow", "green", "cyan", "blue", "magenta"] {
            p.default(name, &fg);
            p.default(
                &format!("bright_{name}"),
                &mix(&p.value(name), Some(WHITE), 0.2),
            );
        }
        p.default("orange", &p.value("yellow"));
        p.default("brown", &mix(&p.value("orange"), Some(BLACK), 0.5));
        p.set("purple", &p.value("magenta"));
        p.set("bright_purple", &p.value("bright_magenta"));

        for (i, key) in ANSI.iter().enumerate() {
            p.set(&format!("color{i}"), &p.value(key));
        }

        if !matches!(p.get("mode"), Some("light" | "dark")) {
            let light = Rgb::parse(&bg).is_some_and(|c| c.brightness() > 382);
            p.set("mode", if light { "light" } else { "dark" });
        }
        p
    }

    fn value(&self, key: &str) -> String {
        self.get(key).unwrap_or_default().to_owned()
    }

    fn set(&mut self, key: &str, value: &str) {
        self.colors.insert(key.to_owned(), value.to_owned());
    }

    fn default(&mut self, key: &str, value: &str) {
        self.colors
            .entry(key.to_owned())
            .or_insert_with(|| value.to_owned());
    }
}

/// `color` blended toward `toward`, or `color` itself when either is not a
/// plain `#rrggbb` (an `rgb()` value, say).
fn mix(color: &str, toward: Option<Rgb>, t: f64) -> String {
    match (Rgb::parse(color), toward) {
        (Some(a), Some(b)) => a.mix(b, t).to_string(),
        _ => color.to_owned(),
    }
}

/// Values are pasted into Hyprland's Lua config, CSS, JSON and TOML, so a
/// quote, brace, backslash or semicolon could let a downloaded theme inject
/// code. Everything a palette needs fits: hex, rgb()/rgba(), gradient angles,
/// decimals and words.
fn valid_value(value: &str) -> bool {
    value
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || "#(),._+/% -".contains(c))
}

fn valid_key(key: &str) -> bool {
    !key.is_empty()
        && key
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

/// Flat `key = "value"` lines. Blank lines, comments and table headers are
/// ignored; invalid entries are returned by key so the caller can warn.
fn parse(text: &str) -> (BTreeMap<String, String>, Vec<String>) {
    let mut colors = BTreeMap::new();
    let mut skipped = Vec::new();
    for line in text.lines() {
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let key = key.trim().trim_matches(|c| c == '"' || c == '\'');
        if key.starts_with('#') {
            continue;
        }
        let value = match value.find(['"', '\'']) {
            Some(open) => {
                let rest = &value[open + 1..];
                rest[..rest.find(['"', '\'']).unwrap_or(rest.len())].to_owned()
            }
            None => match value.split_whitespace().next() {
                // TOML wants it quoted, but a bare #rrggbb is a color, not a
                // comment.
                Some(word) if Rgb::parse(word).is_some() => word.to_owned(),
                // Something like a color that is not one (#rgb, #rrggbbaa):
                // dropping it silently would leave the theme half drawn.
                Some(word) if word.len() > 1 && word.starts_with('#') => {
                    skipped.push(key.to_owned());
                    continue;
                }
                _ => value
                    .split('#')
                    .next()
                    .unwrap_or_default()
                    .split_whitespace()
                    .collect(),
            },
        };
        if !valid_key(key) || !valid_value(&value) {
            skipped.push(key.to_owned());
        } else if !value.is_empty() {
            colors.insert(key.to_owned(), value);
        }
    }
    (colors, skipped)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_quoted_bare_and_commented_values() {
        let (c, skipped) = parse(
            "# palette\nbackground = \"#1a1b26\"\n'accent'='#7aa2f7' # blue\nmode = light # set\n[section]\n",
        );
        assert_eq!(c["background"], "#1a1b26");
        assert_eq!(c["accent"], "#7aa2f7");
        assert_eq!(c["mode"], "light");
        assert!(skipped.is_empty());
    }

    #[test]
    fn takes_a_bare_hex_color_and_reports_a_broken_one() {
        let (c, skipped) = parse("background = #1a1b26 # night\nfoo = #fff\nbar = # nothing yet\n");
        assert_eq!(c["background"], "#1a1b26");
        assert!(!c.contains_key("foo") && !c.contains_key("bar"));
        assert_eq!(skipped, ["foo"]);
    }

    #[test]
    fn rejects_values_that_could_escape_a_template() {
        let (c, skipped) = parse("red = \"#ff0000\"\nevil = \"x\\\" }\"\nlua = \"a;b\"\n");
        assert_eq!(c.len(), 1);
        assert_eq!(skipped, ["evil", "lua"]);
    }

    #[test]
    fn mixes_like_the_reference_awk() {
        let white = Rgb::parse("#ffffff").unwrap();
        let black = Rgb::parse("#000000").unwrap();
        assert_eq!(white.mix(black, 0.43).to_string(), "#919191");
        assert_eq!(black.mix(white, 0.5).to_string(), "#808080");
        assert_eq!(Rgb::parse("#FFFFFF"), Some(white));
        assert_eq!(Rgb::parse("#fff"), None);
    }

    #[test]
    fn reads_amounts_as_fraction_or_percent() {
        assert_eq!(parse_amount("30%"), Some(0.3));
        assert_eq!(parse_amount("0.3"), Some(0.3));
        assert_eq!(parse_amount("30"), Some(0.3));
        assert_eq!(parse_amount("150%"), Some(1.0));
        assert_eq!(parse_amount("x"), None);
    }

    #[test]
    fn derives_missing_shades_and_mode() {
        let p = Palette::from_text("background = \"#ffffff\"\nforeground = \"#000000\"\n");
        assert_eq!(p.get("mode"), Some("light"));
        assert_eq!(p.get("accent"), Some("#000000"));
        assert_eq!(p.get("dark_foreground"), Some("#666666"));
        assert_eq!(p.get("color0"), Some("#ffffff"));
        assert_eq!(p.get("color15"), Some("#000000"));
        assert_eq!(p.get("purple"), p.get("magenta"));
    }

    #[test]
    fn keeps_explicit_values_over_derived_ones() {
        let p =
            Palette::from_text("background = \"#000000\"\nmuted = \"#123456\"\nmode = \"light\"\n");
        assert_eq!(p.get("muted"), Some("#123456"));
        assert_eq!(p.get("mode"), Some("light"));
    }
}
