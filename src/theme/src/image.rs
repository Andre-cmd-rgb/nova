//! A background as a few thousand pixels, to take its colors from.
//!
//! vipsthumbnail, which the picker's thumbnails already need, shrinks the
//! image and writes it as a PPM: a short text header and the pixels as they
//! are, which is read here without an image library.

use std::fs;
use std::path::Path;
use std::process::{self, Command, Stdio};

use crate::error::{bail, Context, Result};
use crate::palette::Rgb;
use crate::paths::Paths;

pub struct Pixels {
    pub width: usize,
    pub height: usize,
    /// Row after row, from the top left.
    pub rgb: Vec<Rgb>,
}

impl Pixels {
    /// `image`, shrunk to fit a square of `size` pixels.
    pub fn load(paths: &Paths, image: &Path, size: u32) -> Result<Pixels> {
        Pixels::thumbnail(paths, image, size, true)
    }

    /// The same, turned as the shell draws it: Qt Quick's Image leaves a
    /// photo's EXIF orientation alone, so this does too.
    pub fn load_as_shown(paths: &Paths, image: &Path, size: u32) -> Result<Pixels> {
        Pixels::thumbnail(paths, image, size, false)
    }

    fn thumbnail(paths: &Paths, image: &Path, size: u32, rotate: bool) -> Result<Pixels> {
        fs::create_dir_all(&paths.runtime).context(paths.runtime.display())?;
        let tmp = paths.runtime.join(format!("sample.{}.ppm", process::id()));
        // vipsthumbnail puts the image's name where its output path has a %s.
        if tmp.to_string_lossy().contains('%') {
            bail!("{}: cannot be written by vipsthumbnail", tmp.display());
        }
        let made = Command::new("vipsthumbnail")
            .arg(image)
            .args(["--size", &format!("{size}x{size}")])
            .args((!rotate).then_some("--no-rotate"))
            .arg("--path")
            .arg(&tmp)
            .env("VIPS_CONCURRENCY", "1")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
        let bytes = fs::read(&tmp);
        let _ = fs::remove_file(&tmp);
        match made {
            Ok(status) if status.success() => {}
            Ok(_) => bail!("{}: vipsthumbnail could not read it", image.display()),
            Err(e) => bail!("vipsthumbnail did not run: {e}"),
        }
        parse_ppm(&bytes.context(tmp.display())?).ok_or_else(|| {
            crate::error::Error::new(format!("{}: not read as pixels", image.display()))
        })
    }

    /// The part of the image a screen of `screen` (width, height) shows: all
    /// of the screen covered, the image centred, what hangs over cut off. Then
    /// of that, the strip `thickness` deep along `edge`, in the screen's
    /// pixels. Returns the strip's rows of pixels, from the screen's edge
    /// inwards.
    pub fn strip(&self, screen: (u32, u32), edge: Edge, thickness: u32) -> Vec<Vec<Rgb>> {
        let (sw, sh) = (f64::from(screen.0), f64::from(screen.1));
        let (iw, ih) = (self.width as f64, self.height as f64);
        if sw <= 0.0 || sh <= 0.0 || self.rgb.is_empty() {
            return Vec::new();
        }
        // The image's pixels per screen pixel, and where the screen starts.
        let scale = (iw / sw).min(ih / sh);
        let (left, top) = ((iw - sw * scale) / 2.0, (ih - sh * scale) / 2.0);
        let (along, across) = match edge {
            Edge::Top | Edge::Bottom => (sw, sh),
            Edge::Left | Edge::Right => (sh, sw),
        };
        let depth = f64::from(thickness).min(across);
        // At least two rows, and a pixel taken once.
        let rows = ((depth * scale).round() as usize).max(2);
        let columns = ((along * scale).round() as usize).max(1);
        let at = |x: f64, y: f64| {
            let column = ((left + x * scale) as usize).min(self.width - 1);
            let row = ((top + y * scale) as usize).min(self.height - 1);
            self.rgb[row * self.width + column]
        };
        (0..rows)
            .map(|row| {
                let inward = (row as f64 + 0.5) / rows as f64 * depth;
                (0..columns)
                    .map(|column| {
                        let run = (column as f64 + 0.5) / columns as f64 * along;
                        match edge {
                            Edge::Top => at(run, inward),
                            Edge::Bottom => at(run, sh - inward),
                            Edge::Left => at(inward, run),
                            Edge::Right => at(sw - inward, run),
                        }
                    })
                    .collect()
            })
            .collect()
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Edge {
    Top,
    Bottom,
    Left,
    Right,
}

impl Edge {
    pub fn parse(word: &str) -> Option<Edge> {
        Some(match word {
            "top" => Edge::Top,
            "bottom" => Edge::Bottom,
            "left" => Edge::Left,
            "right" => Edge::Right,
            _ => return None,
        })
    }
}

/// A binary PPM (P6) or PGM (P5), with 8 or 16 bits to a sample.
fn parse_ppm(bytes: &[u8]) -> Option<Pixels> {
    let mut at = 0;
    // A header field: whitespace and # comments, then a word.
    let mut field = || {
        loop {
            while bytes.get(at)?.is_ascii_whitespace() {
                at += 1;
            }
            if bytes[at] != b'#' {
                break;
            }
            while *bytes.get(at)? != b'\n' {
                at += 1;
            }
        }
        let start = at;
        while at < bytes.len() && !bytes[at].is_ascii_whitespace() {
            at += 1;
        }
        std::str::from_utf8(&bytes[start..at]).ok()
    };
    let channels = match field()? {
        "P6" => 3,
        "P5" => 1,
        _ => return None,
    };
    let width: usize = field()?.parse().ok()?;
    let height: usize = field()?.parse().ok()?;
    let max: usize = field()?.parse().ok()?;
    // One whitespace byte ends the header.
    let data = bytes.get(at + 1..)?;
    let wide = match max {
        1..=255 => 1,
        256..=65535 => 2,
        _ => return None,
    };
    let count = width.checked_mul(height)?;
    if count == 0 || data.len() < count.checked_mul(channels * wide)? {
        return None;
    }
    let sample = |i: usize| {
        let value = if wide == 1 {
            usize::from(data[i])
        } else {
            usize::from(data[i * 2]) << 8 | usize::from(data[i * 2 + 1])
        };
        (value.min(max) * 255 / max) as u8
    };
    let rgb = (0..count)
        .map(|p| match channels {
            3 => Rgb(sample(p * 3), sample(p * 3 + 1), sample(p * 3 + 2)),
            _ => Rgb(sample(p), sample(p), sample(p)),
        })
        .collect();
    Some(Pixels { width, height, rgb })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pixels(width: usize, height: usize, at: impl Fn(usize, usize) -> Rgb) -> Pixels {
        let rgb = (0..width * height)
            .map(|i| at(i % width, i / width))
            .collect();
        Pixels { width, height, rgb }
    }

    #[test]
    fn reads_a_ppm_with_a_comment() {
        let mut bytes = b"P6\n#vips2ppm - a comment\n2 1\n255\n".to_vec();
        bytes.extend([255, 0, 0, 0, 0, 255]);
        let p = parse_ppm(&bytes).unwrap();
        assert_eq!((p.width, p.height), (2, 1));
        assert_eq!(p.rgb, [Rgb(255, 0, 0), Rgb(0, 0, 255)]);
    }

    #[test]
    fn reads_grey_and_sixteen_bits() {
        let p = parse_ppm(b"P5 2 1 255\n\x00\xff").unwrap();
        assert_eq!(p.rgb, [Rgb(0, 0, 0), Rgb(255, 255, 255)]);
        let p = parse_ppm(b"P6 1 1 65535\n\xff\xff\x80\x00\x00\x00").unwrap();
        assert_eq!(p.rgb, [Rgb(255, 127, 0)]);
    }

    #[test]
    fn refuses_what_is_cut_short_or_not_a_ppm() {
        assert!(parse_ppm(b"P6 2 2 255\n\x00\x00\x00").is_none());
        assert!(parse_ppm(b"P3 1 1 255\n0 0 0").is_none());
        assert!(parse_ppm(b"P6 0 1 255\n").is_none());
        assert!(parse_ppm(b"").is_none());
    }

    #[test]
    fn a_strip_is_the_screens_edge_of_the_image_as_it_is_shown() {
        // A 16:9 image on a 4:3 screen loses its sides: the screen shows
        // columns 2 to 13 of 16.
        let image = pixels(16, 9, |x, y| Rgb(x as u8, y as u8, 0));
        let top = image.strip((1200, 900), Edge::Top, 100);
        assert_eq!(top.len(), 2);
        assert_eq!(top[0].first(), Some(&Rgb(2, 0, 0)));
        assert_eq!(top[0].last(), Some(&Rgb(13, 0, 0)));
        let bottom = image.strip((1200, 900), Edge::Bottom, 100);
        assert_eq!(bottom[0].first(), Some(&Rgb(2, 8, 0)));
        let left = image.strip((1200, 900), Edge::Left, 100);
        assert_eq!(left[0].first(), Some(&Rgb(2, 0, 0)));
        assert_eq!(left[0].last(), Some(&Rgb(2, 8, 0)));
        let right = image.strip((1200, 900), Edge::Right, 100);
        assert_eq!(right[0].first(), Some(&Rgb(13, 0, 0)));
    }

    #[test]
    fn a_strip_of_nothing_is_empty() {
        let image = pixels(4, 4, |_, _| Rgb(0, 0, 0));
        assert!(image.strip((0, 0), Edge::Top, 10).is_empty());
    }
}
