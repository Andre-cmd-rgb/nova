//! Color as the eye weighs it: OKLCH for building colors, and WCAG's
//! contrast for checking that one reads on another.
//!
//! OKLCH (Björn Ottosson's Oklab, as lightness, chroma and hue) is where a
//! palette is made from a photo: equal steps in it look equal, so a lightness
//! picked for one hue reads the same in another, which is not true of HSL.

use crate::palette::Rgb;

/// Lightness 0 (black) to 1 (white), chroma from 0 (grey) to about 0.3, and
/// hue in degrees: red near 25, yellow 100, green 145, blue 260, pink 350.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Oklch {
    pub l: f64,
    pub c: f64,
    pub h: f64,
}

fn to_linear(channel: u8) -> f64 {
    let c = f64::from(channel) / 255.0;
    if c <= 0.04045 {
        c / 12.92
    } else {
        ((c + 0.055) / 1.055).powf(2.4)
    }
}

fn from_linear(c: f64) -> f64 {
    if c <= 0.003_130_8 {
        c * 12.92
    } else {
        1.055 * c.powf(1.0 / 2.4) - 0.055
    }
}

impl Oklch {
    pub fn new(l: f64, c: f64, h: f64) -> Oklch {
        Oklch {
            l,
            c,
            h: h.rem_euclid(360.0),
        }
    }

    pub fn from_rgb(rgb: Rgb) -> Oklch {
        let (r, g, b) = (to_linear(rgb.0), to_linear(rgb.1), to_linear(rgb.2));
        let l = (0.412_221_470_8 * r + 0.536_332_536_3 * g + 0.051_445_992_9 * b).cbrt();
        let m = (0.211_903_498_2 * r + 0.680_699_545_1 * g + 0.107_396_956_6 * b).cbrt();
        let s = (0.088_302_461_9 * r + 0.281_718_837_6 * g + 0.629_978_700_5 * b).cbrt();
        let lightness = 0.210_454_255_3 * l + 0.793_617_785 * m - 0.004_072_046_8 * s;
        let a = 1.977_998_495_1 * l - 2.428_592_205 * m + 0.450_593_709_9 * s;
        let b = 0.025_904_037_1 * l + 0.782_771_766_2 * m - 0.808_675_766 * s;
        Oklch::new(lightness, a.hypot(b), b.atan2(a).to_degrees())
    }

    /// The linear sRGB channels, which lie outside 0..1 for a color no screen
    /// shows.
    fn linear(self) -> [f64; 3] {
        let (a, b) = (
            self.c * self.h.to_radians().cos(),
            self.c * self.h.to_radians().sin(),
        );
        let l = (self.l + 0.396_337_777_4 * a + 0.215_803_757_3 * b).powi(3);
        let m = (self.l - 0.105_561_345_8 * a - 0.063_854_172_8 * b).powi(3);
        let s = (self.l - 0.089_484_177_5 * a - 1.291_485_548 * b).powi(3);
        [
            4.076_741_662_1 * l - 3.307_711_591_3 * m + 0.230_969_929_2 * s,
            -1.268_438_004_6 * l + 2.609_757_401_1 * m - 0.341_319_396_5 * s,
            -0.004_196_086_3 * l - 0.703_418_614_7 * m + 1.707_614_701 * s,
        ]
    }

    fn displayable(self) -> bool {
        self.linear().iter().all(|c| (-0.0005..=1.0005).contains(c))
    }

    /// The color as a screen shows it. One too vivid for sRGB keeps its
    /// lightness and hue and gives up chroma, down to the most the screen has.
    pub fn to_rgb(self) -> Rgb {
        let mut color = Oklch {
            l: self.l.clamp(0.0, 1.0),
            ..self
        };
        if !color.displayable() {
            let (mut low, mut high) = (0.0, color.c);
            for _ in 0..20 {
                color.c = (low + high) / 2.0;
                if color.displayable() {
                    low = color.c;
                } else {
                    high = color.c;
                }
            }
            color.c = low;
        }
        let channel = |c: f64| (from_linear(c.clamp(0.0, 1.0)) * 255.0).round() as u8;
        let [r, g, b] = color.linear();
        Rgb(channel(r), channel(g), channel(b))
    }
}

/// The way round the hue circle from `from` to `to`, in -180..=180 degrees.
pub fn hue_turn(from: f64, to: f64) -> f64 {
    (to - from + 180.0).rem_euclid(360.0) - 180.0
}

/// WCAG's relative luminance, 0 to 1.
pub fn luminance(rgb: Rgb) -> f64 {
    0.2126 * to_linear(rgb.0) + 0.7152 * to_linear(rgb.1) + 0.0722 * to_linear(rgb.2)
}

/// WCAG's contrast ratio of two luminances, 1 to 21.
pub fn contrast_of(a: f64, b: f64) -> f64 {
    (a.max(b) + 0.05) / (a.min(b) + 0.05)
}

pub fn contrast(a: Rgb, b: Rgb) -> f64 {
    contrast_of(luminance(a), luminance(b))
}

/// The luminance APCA reads a color's lightness from: a plain 2.4 gamma, and
/// near black lifted a little, as a screen's black is not none.
pub fn apca_luminance(rgb: Rgb) -> f64 {
    let channel = |c: u8| (f64::from(c) / 255.0).powf(2.4);
    let y =
        0.212_672_9 * channel(rgb.0) + 0.715_152_2 * channel(rgb.1) + 0.072_175 * channel(rgb.2);
    if y < 0.022 {
        y + (0.022 - y).powf(1.414)
    } else {
        y
    }
}

/// How well text of luminance `text` reads on a background of luminance
/// `on`: APCA's lightness contrast (Andrew Somers' accessible perceptual
/// contrast algorithm, 0.0.98G), as a size, 0 to about 108. 60 is enough for
/// text to be read and 75 for it to be read at length.
///
/// WCAG's ratio is not used where the choice is between light text and dark:
/// it calls dark text on a mid-tone as readable as it calls light text
/// unreadable there, and the eye finds them alike.
pub fn apca_of(text: f64, on: f64) -> f64 {
    let contrast = if on > text {
        (on.powf(0.56) - text.powf(0.57)) * 1.14
    } else {
        (on.powf(0.65) - text.powf(0.62)) * 1.14
    };
    if contrast.abs() < 0.1 {
        0.0
    } else {
        (contrast.abs() - 0.027) * 100.0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rgb(hex: &str) -> Rgb {
        Rgb::parse(hex).unwrap()
    }

    #[test]
    fn goes_to_oklch_and_back() {
        for hex in [
            "#000000", "#ffffff", "#7aa2f7", "#f7768e", "#1a1b26", "#9ece6a",
        ] {
            assert_eq!(Oklch::from_rgb(rgb(hex)).to_rgb(), rgb(hex), "{hex}");
        }
    }

    #[test]
    fn reads_the_reference_colors() {
        // Ottosson's table: white is L 1 with no chroma, and sRGB's red, green
        // and blue lie at hues 29, 142 and 264.
        let white = Oklch::from_rgb(rgb("#ffffff"));
        assert!((white.l - 1.0).abs() < 1e-4 && white.c < 1e-4);
        for (hex, l, c, h) in [
            ("#ff0000", 0.628, 0.2577, 29.23),
            ("#00ff00", 0.8664, 0.2948, 142.5),
            ("#0000ff", 0.452, 0.3132, 264.05),
        ] {
            let got = Oklch::from_rgb(rgb(hex));
            assert!((got.l - l).abs() < 2e-3, "{hex} L {}", got.l);
            assert!((got.c - c).abs() < 2e-3, "{hex} C {}", got.c);
            assert!((got.h - h).abs() < 0.2, "{hex} h {}", got.h);
        }
    }

    #[test]
    fn a_color_too_vivid_keeps_its_lightness_and_hue() {
        let asked = Oklch::new(0.8, 0.4, 150.0);
        let shown = Oklch::from_rgb(asked.to_rgb());
        assert!((shown.l - 0.8).abs() < 0.01, "L {}", shown.l);
        assert!(hue_turn(shown.h, 150.0).abs() < 2.0, "h {}", shown.h);
        assert!(shown.c < 0.3);
    }

    #[test]
    fn turns_the_short_way_round() {
        assert_eq!(hue_turn(350.0, 10.0), 20.0);
        assert_eq!(hue_turn(10.0, 350.0), -20.0);
        assert_eq!(hue_turn(0.0, 180.0), -180.0);
    }

    #[test]
    fn measures_lightness_contrast_as_apca_does() {
        // APCA's own reference pairs.
        let lc = |text: &str, on: &str| apca_of(apca_luminance(rgb(text)), apca_luminance(rgb(on)));
        assert!((lc("#000000", "#ffffff") - 106.0).abs() < 0.2);
        assert!((lc("#ffffff", "#000000") - 107.9).abs() < 0.2);
        assert!((lc("#888888", "#ffffff") - 63.1).abs() < 0.2);
        assert!((lc("#ffffff", "#888888") - 68.5).abs() < 0.2);
        assert_eq!(lc("#777777", "#7a7a7a"), 0.0);
    }

    #[test]
    fn measures_contrast_as_wcag_does() {
        assert!((contrast(rgb("#000000"), rgb("#ffffff")) - 21.0).abs() < 1e-9);
        assert!((contrast(rgb("#777777"), rgb("#ffffff")) - 4.48).abs() < 0.01);
        assert_eq!(contrast(rgb("#123456"), rgb("#123456")), 1.0);
    }
}
