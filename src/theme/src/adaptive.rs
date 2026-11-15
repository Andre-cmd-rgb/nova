//! A palette taken from a background: the adaptive theme.
//!
//! The photo gives three things: the hue most of it is (the tint of every
//! surface and of the text), the hue that stands out in it (the accent, and
//! with the tint the window border's gradient), and how vivid it is (how much
//! color the palette carries). Whether the theme is dark or light follows the
//! photo's own lightness.
//!
//! Lightness is not taken from the photo. Each role has its own, the same for
//! every photo, so text reads on its surface whatever the photo is; the
//! terminal's six colors keep their hues, since red has to stay red, and lean
//! a little toward the accent so they sit with it.

use std::fmt::Write;

use crate::color::{contrast, hue_turn, Oklch};
use crate::palette::Rgb;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    Dark,
    Light,
}

impl Mode {
    pub fn parse(word: &str) -> Option<Mode> {
        match word {
            "dark" => Some(Mode::Dark),
            "light" => Some(Mode::Light),
            _ => None,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Mode::Dark => "dark",
            Mode::Light => "light",
        }
    }
}

/// What a photo is read as.
#[derive(Clone, Copy, Debug)]
pub struct Reading {
    /// Dark or light: the one asked for, else the photo's own.
    pub mode: Mode,
    /// The hue most of the photo's surfaces-to-be are, and how much chroma
    /// that part has.
    pub tint: f64,
    pub tint_chroma: f64,
    /// The hue that stands out, and the next one that does.
    pub accent: f64,
    pub second: f64,
    /// 0 for a grey photo, 1 for a vivid one, a little over for neon.
    pub vivid: f64,
}

/// A photo lighter than this gives a light theme.
const LIGHT_FROM: f64 = 0.7;
/// Chroma below this is grey: it has a hue only by rounding.
const GREY: f64 = 0.02;
/// A hue counts as the photo's only where this share of it has it.
const MIN_SHARE: f64 = 0.01;
const BINS: usize = 72;
const BIN_DEGREES: f64 = 360.0 / BINS as f64;

fn bin_of(hue: f64) -> usize {
    ((hue.rem_euclid(360.0) / BIN_DEGREES) as usize).min(BINS - 1)
}

fn hue_of(bin: usize) -> f64 {
    (bin as f64 + 0.5) * BIN_DEGREES
}

/// Each bin with its neighbours up to 15 degrees away, the nearer the more.
fn smoothed(bins: &[f64; BINS]) -> [f64; BINS] {
    let mut out = [0.0; BINS];
    for (i, value) in out.iter_mut().enumerate() {
        for offset in -3_i32..=3 {
            let weight = 1.0 - f64::from(offset.abs()) / 4.0;
            *value += bins[(i as i32 + offset).rem_euclid(BINS as i32) as usize] * weight;
        }
    }
    out
}

fn peak(bins: &[f64; BINS], score: impl Fn(usize, f64) -> f64) -> Option<usize> {
    (0..BINS)
        .map(|i| (i, score(i, bins[i])))
        .filter(|(_, s)| *s > 0.0)
        .max_by(|a, b| a.1.total_cmp(&b.1))
        .map(|(i, _)| i)
}

pub fn read(pixels: &[Rgb], mode: Option<Mode>) -> Reading {
    let colors: Vec<Oklch> = pixels.iter().map(|&p| Oklch::from_rgb(p)).collect();
    let count = colors.len().max(1) as f64;
    let lightness = colors.iter().map(|c| c.l).sum::<f64>() / count;
    let mode = mode.unwrap_or(if lightness > LIGHT_FROM {
        Mode::Light
    } else {
        Mode::Dark
    });

    // How much of the photo has each hue, and how much color is there. Very
    // dark and very light pixels have little hue to see, so they count less.
    // The tint is for the theme's surfaces, so a dark theme takes it from
    // the photo's darker parts and a light theme from its lighter ones: a
    // print of a dark wave on pale paper gives a dark theme the wave's blue.
    let mut area = [0.0; BINS];
    let mut energy = [0.0; BINS];
    let mut chroma = [0.0; BINS];
    let mut present = [0.0; BINS];
    let mut chromas: Vec<f64> = Vec::new();
    for c in colors.iter().filter(|c| c.c >= GREY) {
        let seen = (1.0 - ((c.l - 0.55).abs() / 0.5).powi(2)).max(0.1);
        let surface = match mode {
            Mode::Dark => (0.8 - c.l) / 0.5,
            Mode::Light => (c.l - 0.3) / 0.5,
        }
        .clamp(0.05, 1.0);
        let bin = bin_of(c.h);
        area[bin] += seen * surface;
        energy[bin] += c.c.powi(3) * seen;
        chroma[bin] += c.c * seen * surface;
        present[bin] += 1.0;
        chromas.push(c.c);
    }
    let colored = chromas.len() as f64 / count;
    chromas.sort_by(f64::total_cmp);
    let strong = chromas
        .get(chromas.len() * 9 / 10)
        .copied()
        .unwrap_or_default();
    // A photo with next to no color is a grey one.
    let vivid = if colored < 0.04 {
        0.0
    } else {
        (strong / 0.14).clamp(0.45, 1.15) * (colored / 0.25).clamp(0.5, 1.0)
    };

    let (area_s, energy_s) = (smoothed(&area), smoothed(&energy));
    let tint_bin = peak(&area_s, |_, v| v).unwrap_or(bin_of(265.0));
    let tint = hue_of(tint_bin);
    // A hue's bins: its own and those within 15 degrees.
    let around = |bin: usize, of: &[f64; BINS]| -> f64 {
        (-3_i32..=3)
            .map(|o| of[(bin as i32 + o).rem_euclid(BINS as i32) as usize])
            .sum()
    };
    let tint_chroma = around(tint_bin, &chroma) / around(tint_bin, &area).max(1e-9);

    // The accent is where the color is strongest, and better away from the
    // tint, which is already everywhere; a hue only a speck has is passed over.
    let share = |bin: usize| around(bin, &present) / count;
    let away = |bin: usize, from: f64| (hue_turn(hue_of(bin), from).abs() / 60.0).min(1.0);
    let accent_bin = peak(&energy_s, |bin, v| {
        if share(bin) < MIN_SHARE {
            return 0.0;
        }
        v * (0.45 + 0.55 * away(bin, tint))
    })
    .unwrap_or(tint_bin);
    let accent = hue_of(accent_bin);
    // The second is the next that stands out, a clear step from the accent;
    // with none, the tint, and with the tint beside the accent, a step on.
    let second = peak(&energy_s, |bin, v| {
        if share(bin) < MIN_SHARE || hue_turn(hue_of(bin), accent).abs() < 40.0 {
            return 0.0;
        }
        v
    })
    .map(hue_of)
    .unwrap_or(tint);
    let second = if hue_turn(second, accent).abs() < 25.0 {
        accent + 40.0
    } else {
        second
    };

    Reading {
        mode,
        tint,
        tint_chroma,
        accent,
        second,
        vivid,
    }
}

/// A color of `hue` at lightness `l` and chroma `c`, moved lighter or darker
/// until it stands `ratio` to 1 against `on`.
fn readable(l: f64, c: f64, hue: f64, on: Rgb, ratio: f64, mode: Mode) -> Rgb {
    let step = match mode {
        Mode::Dark => 0.01,
        Mode::Light => -0.01,
    };
    let mut l = l;
    loop {
        let color = Oklch::new(l, c, hue).to_rgb();
        if contrast(color, on) >= ratio || !(0.05..=0.97).contains(&(l + step)) {
            return color;
        }
        l += step;
    }
}

/// The terminal's six, and orange: name, hue, and how much lighter than the
/// rest it is drawn (yellow and green look dark at the lightness of a blue).
const HUES: [(&str, f64, f64); 7] = [
    ("red", 22.0, 0.0),
    ("orange", 55.0, 0.02),
    ("yellow", 92.0, 0.07),
    ("green", 146.0, 0.04),
    ("cyan", 205.0, 0.04),
    ("blue", 258.0, 0.0),
    ("magenta", 322.0, 0.0),
];

pub struct Palette {
    pub mode: Mode,
    colors: Vec<(String, Rgb)>,
    border: (Rgb, Rgb),
}

impl Palette {
    pub fn from_reading(r: &Reading) -> Palette {
        let mode = r.mode;
        let grey = r.vivid == 0.0;
        // Surfaces carry a little of the tint, more where the photo has more.
        let wash = if grey {
            0.0
        } else {
            (0.012 + r.tint_chroma * 0.22).min(0.04)
        };
        let v = r.vivid;
        let at = |l: f64, c: f64, h: f64| Oklch::new(l, c, h).to_rgb();
        let mut colors: Vec<(String, Rgb)> = Vec::new();
        let mut put = |name: &str, color: Rgb| colors.push((name.to_owned(), color));

        let (background, accent, second) = match mode {
            Mode::Dark => {
                let background = at(0.215, wash, r.tint);
                put("background", background);
                put("dark_background", at(0.18, wash, r.tint));
                put("lighter_background", at(0.29, wash * 1.25, r.tint));
                put("selection", at(0.36, 0.035 + 0.045 * v, r.accent));
                put("foreground", at(0.91, wash * 0.6, r.tint));
                put("light_foreground", at(0.81, wash * 0.9, r.tint));
                put("dark_foreground", at(0.5, wash * 1.1, r.tint));
                put(
                    "muted",
                    readable(0.56, wash * 1.3, r.tint, background, 3.6, mode),
                );
                let chroma = 0.05 + 0.1 * v;
                (
                    background,
                    readable(0.79, chroma, r.accent, background, 6.5, mode),
                    readable(0.75, chroma, r.second, background, 5.0, mode),
                )
            }
            Mode::Light => {
                let background = at(0.968, wash * 0.35, r.tint);
                put("background", background);
                put("dark_background", at(0.94, wash * 0.45, r.tint));
                put("lighter_background", at(0.885, wash * 0.6, r.tint));
                put("selection", at(0.86, 0.02 + 0.03 * v, r.accent));
                put("foreground", at(0.27, wash * 0.8, r.tint));
                put("light_foreground", at(0.38, wash * 0.8, r.tint));
                put("dark_foreground", at(0.68, wash * 0.7, r.tint));
                put(
                    "muted",
                    readable(0.58, wash * 0.8, r.tint, background, 3.6, mode),
                );
                let chroma = 0.06 + 0.12 * v;
                (
                    background,
                    readable(0.52, chroma, r.accent, background, 5.0, mode),
                    readable(0.58, chroma, r.second, background, 3.6, mode),
                )
            }
        };
        put("accent", accent);

        // Each of the terminal's hues leans a quarter of the way to the
        // accent, twelve degrees at most.
        let (base, chroma, ratio) = match mode {
            Mode::Dark => (0.76, 0.045 + 0.085 * v, 5.0),
            Mode::Light => (0.53, 0.06 + 0.1 * v, 4.5),
        };
        for (name, hue, lift) in HUES {
            let lean = if grey {
                0.0
            } else {
                (hue_turn(hue, r.accent) * 0.25).clamp(-12.0, 12.0)
            };
            let lift = match mode {
                Mode::Dark => lift,
                Mode::Light => lift * 0.6,
            };
            let color = readable(base + lift, chroma, hue + lean, background, ratio, mode);
            put(name, color);
            if name != "orange" {
                let bright = match mode {
                    Mode::Dark => base + lift + 0.06,
                    Mode::Light => base + lift - 0.06,
                };
                put(
                    &format!("bright_{name}"),
                    readable(bright, chroma * 1.05, hue + lean, background, ratio, mode),
                );
            }
        }

        Palette {
            mode,
            colors,
            border: (accent, second),
        }
    }

    #[cfg(test)]
    pub fn get(&self, name: &str) -> Option<Rgb> {
        self.colors.iter().find(|(n, _)| n == name).map(|(_, c)| *c)
    }

    /// The palette as a colors.toml, with `header` as its comment.
    pub fn to_toml(&self, header: &str) -> String {
        let mut out = String::new();
        for line in header.lines() {
            let _ = writeln!(out, "# {line}");
        }
        let _ = writeln!(out, "mode = \"{}\"", self.mode.name());
        for (name, color) in &self.colors {
            let _ = writeln!(out, "{name} = \"{color}\"");
        }
        // The focused window's border runs from the accent to the photo's
        // second color.
        let _ = writeln!(
            out,
            "hyprland_active_border = \"{} {} 45deg\"",
            self.border.0, self.border.1
        );
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::color::luminance;

    fn field(l: f64, c: f64, h: f64, count: usize) -> Vec<Rgb> {
        vec![Oklch::new(l, c, h).to_rgb(); count]
    }

    /// A dusk: mostly deep blue, a band of pink, a little orange.
    fn dusk() -> Vec<Rgb> {
        let mut p = field(0.35, 0.09, 262.0, 700);
        p.extend(field(0.65, 0.14, 345.0, 220));
        p.extend(field(0.75, 0.13, 60.0, 80));
        p
    }

    #[test]
    fn the_tint_is_what_most_of_the_photo_is_and_the_accent_what_stands_out() {
        let r = read(&dusk(), None);
        assert!(hue_turn(r.tint, 262.0).abs() < 8.0, "tint {}", r.tint);
        assert!(hue_turn(r.accent, 345.0).abs() < 8.0, "accent {}", r.accent);
        assert!(r.vivid > 0.5);
    }

    #[test]
    fn a_speck_of_color_is_not_the_accent() {
        let mut p = field(0.4, 0.08, 150.0, 2000);
        p.extend(field(0.6, 0.25, 30.0, 3));
        let r = read(&p, None);
        assert!(hue_turn(r.accent, 150.0).abs() < 8.0, "accent {}", r.accent);
    }

    #[test]
    fn a_dark_photo_gives_a_dark_theme_and_a_light_one_a_light_theme() {
        assert_eq!(read(&dusk(), None).mode, Mode::Dark);
        let snow = field(0.93, 0.02, 240.0, 500);
        assert_eq!(read(&snow, None).mode, Mode::Light);
        assert_eq!(read(&snow, Some(Mode::Dark)).mode, Mode::Dark);
    }

    #[test]
    fn everything_reads_on_its_background_in_both_modes() {
        for pixels in [
            dusk(),
            field(0.5, 0.2, 140.0, 400),
            field(0.9, 0.03, 80.0, 400),
        ] {
            for mode in [Mode::Dark, Mode::Light] {
                let p = Palette::from_reading(&read(&pixels, Some(mode)));
                let background = p.get("background").unwrap();
                let against = |name: &str| contrast(p.get(name).unwrap(), background);
                assert!(against("foreground") >= 10.0, "{mode:?} foreground");
                assert!(against("accent") >= 4.5, "{mode:?} accent");
                assert!(against("muted") >= 3.5, "{mode:?} muted");
                for name in ["red", "green", "yellow", "blue", "magenta", "cyan"] {
                    assert!(against(name) >= 4.4, "{mode:?} {name} {}", against(name));
                }
            }
        }
    }

    #[test]
    fn a_grey_photo_gives_grey_surfaces() {
        let r = read(&field(0.4, 0.0, 0.0, 300), None);
        assert_eq!(r.vivid, 0.0);
        let p = Palette::from_reading(&r);
        let Rgb(red, green, blue) = p.get("background").unwrap();
        assert!(red.abs_diff(green) <= 1 && green.abs_diff(blue) <= 1);
        // The terminal still tells red from green.
        assert_ne!(p.get("red"), p.get("green"));
    }

    #[test]
    fn red_stays_red_whatever_the_accent() {
        for accent in [0.0, 90.0, 180.0, 270.0] {
            let p = Palette::from_reading(&read(&field(0.5, 0.15, accent, 300), Some(Mode::Dark)));
            let red = Oklch::from_rgb(p.get("red").unwrap());
            assert!(hue_turn(red.h, 22.0).abs() <= 14.0, "red at {}", red.h);
        }
    }

    #[test]
    fn writes_a_palette_the_engine_reads() {
        let text = Palette::from_reading(&read(&dusk(), None)).to_toml("From a test.\nTwo lines.");
        assert!(text.starts_with("# From a test.\n# Two lines.\nmode = \"dark\"\n"));
        let parsed = crate::palette::Palette::from_text(&text);
        assert!(parsed
            .rgb("background")
            .is_some_and(|c| luminance(c) < 0.05));
        assert!(parsed
            .get("hyprland_active_border")
            .is_some_and(|b| b.ends_with("45deg")));
        assert_eq!(parsed.get("color1"), parsed.get("red"));
    }
}
