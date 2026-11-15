//! What a see-through bar needs to be read on the background behind it.
//!
//! A bar with no surface of its own has only its text, on whatever part of the
//! photo lies along that edge of the screen. Two things make it readable: the
//! ink, which is the theme's text color or, on a pale photo under a dark
//! theme, its background color; and a shade, a gradient of the other color
//! that is deepest at the screen's edge and gone a little past the bar. The
//! shade is only as strong as the photo there needs: over a dark sky there is
//! none, and the bar is the photo and the text.

use std::fs;

use crate::color::{apca_luminance, apca_of};
use crate::image::{Edge, Pixels};
use crate::palette::Rgb;
use crate::paths::Paths;

/// How large the background is read for the strip behind the bar: a bar is a
/// fortieth of the screen's height, and needs a few rows of pixels.
const SAMPLE_SIZE: u32 = 640;

/// The lightness contrast (APCA) the text is given against what is behind
/// it: a bar is short words in a small size, to be read at a glance.
const CONTRAST: f64 = 60.0;
/// The share of the strip that may fall short of it: a moon, a streak of
/// cloud.
const MAY_FALL_SHORT: f64 = 0.1;
/// The shade behind the text is this much of its strength at the edge, as the
/// shell draws it: the gradient has begun to fade where the text's foot is.
pub const AT_THE_TEXT: f64 = 0.72;
/// No shade is drawn stronger than this at the edge.
const STRONGEST: f64 = 0.9;
/// How much more shade the theme's own text color may need than the other
/// before the other is used: the bar keeps the theme's look where it can.
const OWN_BY: f64 = 0.16;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Ink {
    /// The color of the bar's text.
    pub ink: Rgb,
    /// The shade's color, and its opacity at the screen's edge, 0 for none.
    pub shade: Rgb,
    pub strength: f64,
}

/// How opaque a layer of `shade` over `strip` must be for `ink` to read on
/// all but a little of it; `None` when no layer does it.
fn layer_needed(strip: &[Rgb], ink: Rgb, shade: Rgb) -> Option<f64> {
    let ink = apca_luminance(ink);
    let may_fail = (strip.len() as f64 * MAY_FALL_SHORT) as usize;
    (0..=50).map(|step| f64::from(step) / 50.0).find(|&alpha| {
        let short = strip
            .iter()
            .filter(|&&pixel| apca_of(ink, apca_luminance(pixel.mix(shade, alpha))) < CONTRAST)
            .count();
        short <= may_fail
    })
}

/// The ink and shade for a bar over `strip`, the photo's pixels behind it, in
/// a theme whose text is `text` on `backdrop`.
pub fn ink(strip: &[Rgb], text: Rgb, backdrop: Rgb) -> Ink {
    let plain = Ink {
        ink: text,
        shade: backdrop,
        strength: 0.0,
    };
    if strip.is_empty() {
        return plain;
    }
    let own = layer_needed(strip, text, backdrop);
    let other = layer_needed(strip, backdrop, text);
    let (ink, shade, layer) = match (own, other) {
        (Some(own), Some(other)) if other + OWN_BY < own => (backdrop, text, other),
        (Some(own), _) => (text, backdrop, own),
        (None, Some(other)) => (backdrop, text, other),
        // Text and background too alike for either to read on the other:
        // nothing here can help.
        (None, None) => return plain,
    };
    Ink {
        ink,
        shade,
        strength: (layer / AT_THE_TEXT).min(STRONGEST),
    }
}

/// The ink and shade for a bar `thickness` deep along `edge` of a screen of
/// `screen` pixels, over the background in use. With no background that can
/// be read, the theme's text and no shade.
pub fn on_background(
    paths: &Paths,
    edge: Edge,
    thickness: u32,
    screen: (u32, u32),
    text: Rgb,
    backdrop: Rgb,
) -> Ink {
    let strip: Vec<Rgb> = fs::canonicalize(paths.background())
        .ok()
        .and_then(|image| Pixels::load(paths, &image, SAMPLE_SIZE).ok())
        .map(|pixels| pixels.strip(screen, edge, thickness))
        .unwrap_or_default()
        .into_iter()
        .flatten()
        .collect();
    ink(&strip, text, backdrop)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn reads(text: Rgb, on: Rgb) -> f64 {
        apca_of(apca_luminance(text), apca_luminance(on))
    }

    const TEXT: Rgb = Rgb(0xc0, 0xca, 0xf5);
    const NIGHT: Rgb = Rgb(0x1a, 0x1b, 0x26);

    #[test]
    fn a_dark_photo_needs_no_shade() {
        let got = ink(&[Rgb(20, 24, 40); 200], TEXT, NIGHT);
        assert_eq!((got.ink, got.strength), (TEXT, 0.0));
    }

    #[test]
    fn a_pale_photo_takes_the_dark_ink_and_no_shade() {
        let got = ink(&[Rgb(240, 240, 235); 200], TEXT, NIGHT);
        assert_eq!((got.ink, got.shade, got.strength), (NIGHT, TEXT, 0.0));
    }

    #[test]
    fn a_photo_in_between_is_shaded_until_the_text_reads() {
        // A pink dusk: neither color reads on it as it is.
        let dusk = Rgb(0xa0, 0x6c, 0xa8);
        assert!(reads(TEXT, dusk) < CONTRAST && reads(NIGHT, dusk) < CONTRAST);
        let got = ink(&[dusk; 200], TEXT, NIGHT);
        assert_eq!((got.ink, got.shade), (TEXT, NIGHT));
        assert!(
            got.strength > 0.2 && got.strength < STRONGEST,
            "{}",
            got.strength
        );
        let behind = dusk.mix(NIGHT, got.strength * AT_THE_TEXT);
        assert!(reads(TEXT, behind) >= CONTRAST - 2.0);
    }

    #[test]
    fn a_speck_of_light_does_not_shade_the_bar() {
        let mut sky = vec![Rgb(18, 22, 44); 190];
        sky.extend([Rgb(250, 250, 240); 10]);
        assert_eq!(ink(&sky, TEXT, NIGHT).strength, 0.0);
    }

    #[test]
    fn half_dark_and_half_bright_keeps_the_themes_ink_and_shades() {
        let mut sky = vec![Rgb(18, 22, 44); 100];
        sky.extend([Rgb(0xd0, 0x90, 0xb0); 100]);
        let got = ink(&sky, TEXT, NIGHT);
        assert_eq!(got.ink, TEXT);
        assert!(got.strength > 0.0);
    }

    #[test]
    fn a_light_theme_is_the_same_the_other_way_round() {
        let (text, paper) = (Rgb(0x12, 0x12, 0x12), Rgb(0xff, 0xff, 0xff));
        assert_eq!(ink(&[Rgb(235, 235, 235); 50], text, paper).strength, 0.0);
        let night = ink(&[Rgb(10, 10, 20); 50], text, paper);
        assert_eq!((night.ink, night.strength), (paper, 0.0));
    }

    #[test]
    fn nothing_to_measure_is_the_themes_text_unshaded() {
        assert_eq!(ink(&[], TEXT, NIGHT).strength, 0.0);
        assert_eq!(ink(&[], TEXT, NIGHT).ink, TEXT);
    }
}
