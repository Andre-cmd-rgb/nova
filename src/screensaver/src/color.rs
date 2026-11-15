//! Colors for a black screen: the theme's two, and what is made of them.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Rgb(pub u8, pub u8, pub u8);

pub const WHITE: Rgb = Rgb(255, 255, 255);
pub const BLACK: Rgb = Rgb(0, 0, 0);

impl Rgb {
    /// `#rrggbb`.
    pub fn parse(text: &str) -> Option<Rgb> {
        let hex = text.strip_prefix('#')?;
        if hex.len() != 6 || !hex.is_ascii() {
            return None;
        }
        let part = |at: usize| u8::from_str_radix(&hex[at..at + 2], 16).ok();
        Some(Rgb(part(0)?, part(2)?, part(4)?))
    }

    /// From this color to `other` as `amount` goes from 0 to 1.
    pub fn mix(self, other: Rgb, amount: f64) -> Rgb {
        let amount = amount.clamp(0.0, 1.0);
        let part =
            |a: u8, b: u8| (f64::from(a) + (f64::from(b) - f64::from(a)) * amount).round() as u8;
        Rgb(
            part(self.0, other.0),
            part(self.1, other.1),
            part(self.2, other.2),
        )
    }

    /// As bright as `amount` of itself: 0 is black.
    pub fn dim(self, amount: f64) -> Rgb {
        BLACK.mix(self, amount)
    }

    /// The same hue, as bright as a black screen wants it: a theme's accent is
    /// chosen against the theme's own background, and a light theme's is dark.
    pub fn lit(self) -> Rgb {
        let (hue, saturation, _) = self.hsv();
        from_hsv(hue, saturation.min(0.75), 1.0)
    }

    /// The hue turned by `degrees`.
    pub fn turned(self, degrees: f64) -> Rgb {
        let (hue, saturation, value) = self.hsv();
        from_hsv((hue + degrees).rem_euclid(360.0), saturation, value)
    }

    /// Hue in degrees, saturation and value from 0 to 1.
    fn hsv(self) -> (f64, f64, f64) {
        let (r, g, b) = (
            f64::from(self.0) / 255.0,
            f64::from(self.1) / 255.0,
            f64::from(self.2) / 255.0,
        );
        let (high, low) = (r.max(g).max(b), r.min(g).min(b));
        let spread = high - low;
        let hue = if spread == 0.0 {
            0.0
        } else if high == r {
            60.0 * ((g - b) / spread).rem_euclid(6.0)
        } else if high == g {
            60.0 * ((b - r) / spread + 2.0)
        } else {
            60.0 * ((r - g) / spread + 4.0)
        };
        (hue, if high == 0.0 { 0.0 } else { spread / high }, high)
    }
}

fn from_hsv(hue: f64, saturation: f64, value: f64) -> Rgb {
    let chroma = value * saturation;
    let sector = hue / 60.0;
    let second = chroma * (1.0 - (sector.rem_euclid(2.0) - 1.0).abs());
    let (r, g, b) = match sector as u32 {
        0 => (chroma, second, 0.0),
        1 => (second, chroma, 0.0),
        2 => (0.0, chroma, second),
        3 => (0.0, second, chroma),
        4 => (second, 0.0, chroma),
        _ => (chroma, 0.0, second),
    };
    let lift = value - chroma;
    let part = |x: f64| ((x + lift) * 255.0).round().clamp(0.0, 255.0) as u8;
    Rgb(part(r), part(g), part(b))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_a_hex_color_and_nothing_else() {
        assert_eq!(Rgb::parse("#cba6ff"), Some(Rgb(0xcb, 0xa6, 0xff)));
        assert_eq!(Rgb::parse("cba6ff"), None);
        assert_eq!(Rgb::parse("#cba6f"), None);
        assert_eq!(Rgb::parse("#cba6fg"), None);
        assert_eq!(Rgb::parse("#ćba6f"), None);
    }

    #[test]
    fn mixes_from_one_to_the_other() {
        let (a, b) = (Rgb(0, 100, 200), Rgb(200, 100, 0));
        assert_eq!(a.mix(b, 0.0), a);
        assert_eq!(a.mix(b, 1.0), b);
        assert_eq!(a.mix(b, 0.5), Rgb(100, 100, 100));
        assert_eq!(a.mix(b, 7.0), b);
        assert_eq!(a.dim(0.0), BLACK);
        assert_eq!(a.dim(1.0), a);
    }

    #[test]
    fn a_dark_accent_is_lit_for_a_black_screen_in_its_own_hue() {
        let navy = Rgb(0x20, 0x5e, 0xa6);
        let lit = navy.lit();
        assert_eq!(lit.0.max(lit.1).max(lit.2), 255);
        assert!(lit.2 > lit.1 && lit.1 > lit.0, "{lit:?} is still blue");
        // A grey has no hue to keep: it becomes white.
        assert_eq!(Rgb(90, 90, 90).lit(), WHITE);
    }

    #[test]
    fn turning_the_hue_all_the_way_round_changes_nothing() {
        let color = Rgb(203, 166, 255);
        let round = color.turned(360.0);
        for (a, b) in [(color.0, round.0), (color.1, round.1), (color.2, round.2)] {
            assert!(a.abs_diff(b) <= 1);
        }
        assert_eq!(Rgb(255, 0, 0).turned(120.0), Rgb(0, 255, 0));
    }
}
