//! The lock screen's backdrop: the background as the lock shows it, small
//! and already blurred, made whenever the background changes.
//!
//! The lock and the greeter draw it in their first frame: a few hundred
//! pixels a side read in a millisecond or two, where the background itself
//! (a 4K photo) took a third of a second to decode, a moment the lock showed
//! a flat colour in, and blurring it on the graphics card held some 200 MB
//! for as long as the lock was up. The screen scales it up smoothly; at this
//! blur nothing finer than a few of its pixels is left to lose.
//!
//! The blur is the one the lock drew before (Qt's MultiEffect, blur 1.0 to a
//! blurMax of 128 with a multiplier of 1.25, contrast -0.08), measured on a
//! ThinkPad P1's 2400×1500 logical screen: a black and white edge through it
//! is a flat disc of 115 logical pixels' radius, softened by a Gaussian of
//! 25, within 1.4 levels of 255 everywhere (0.5 on average). Those are taken
//! here as parts of the width a 16:10 screen shows of the picture, so that
//! the lock looks the same on that screen; on a screen of another size the
//! blur keeps its share of the picture, where the old one kept its pixels.
//!
//! It is a PPM, which Qt reads with no plugin and this writes with no
//! library: some 250 KB in the state directory.

use std::fs;
use std::path::{Path, PathBuf};

use crate::error::Result;
use crate::fsutil::{remove_if_present, write_atomic};
use crate::image::Pixels;
use crate::palette::Rgb;
use crate::paths::Paths;

/// The file's name, beside `current/background`; the greeter's mirror has
/// it by the same name (nova-theme-apply).
pub const FILE: &str = "backdrop.ppm";

/// The backdrop's longer side, in pixels.
const SIZE: u32 = 384;

/// The disc's radius and the Gaussian's sigma, as parts of the width a 16:10
/// screen shows of the picture (184 and 40 of a P1's 3840 pixels).
const DISC: f32 = 184.0 / 3840.0;
const SOFTEN: f32 = 40.0 / 3840.0;

/// MultiEffect's contrast of -0.08: each value moved toward the middle.
const CONTRAST: f32 = 0.92;

pub fn path(paths: &Paths) -> PathBuf {
    paths.current().join(FILE)
}

/// Makes the backdrop of the background in use. One that cannot be made is
/// removed, so that the lock never shows the backdrop of another picture:
/// without one it draws the background itself, as it did before.
pub fn make(paths: &Paths) -> Result<()> {
    let file = path(paths);
    let made = fs::canonicalize(paths.background())
        .map_err(|e| crate::error::Error::new(format!("{}: {e}", paths.background().display())))
        .and_then(|picture| Pixels::load_as_shown(paths, &picture, SIZE))
        .and_then(|pixels| write_atomic(&file, ppm(&blur(&pixels))));
    if made.is_err() {
        let _ = remove_if_present(&file);
    }
    made
}

/// Makes the backdrop again unless the one there is newer than the
/// background's link, which every change of background replaces.
pub fn refresh(paths: &Paths) -> Result<()> {
    let modified = |path: &Path| fs::symlink_metadata(path).and_then(|m| m.modified()).ok();
    match (modified(&path(paths)), modified(&paths.background())) {
        (_, None) => Ok(()),
        (Some(backdrop), Some(link)) if backdrop >= link => Ok(()),
        _ => make(paths),
    }
}

/// `pixels` blurred and its contrast taken down as the lock shows them.
pub fn blur(pixels: &Pixels) -> Pixels {
    let (width, height) = (pixels.width, pixels.height);
    let shown = (width as f32).min(height as f32 * 1.6);
    let radius = DISC * shown;
    let sigma = SOFTEN * shown;
    let mut planes: [Vec<f32>; 3] = [
        pixels.rgb.iter().map(|p| f32::from(p.0)).collect(),
        pixels.rgb.iter().map(|p| f32::from(p.1)).collect(),
        pixels.rgb.iter().map(|p| f32::from(p.2)).collect(),
    ];
    for plane in &mut planes {
        *plane = disc(plane, width, height, radius);
        gaussian(plane, width, height, sigma);
    }
    let level = |v: f32| ((v - 127.5) * CONTRAST + 127.5).round().clamp(0.0, 255.0) as u8;
    let rgb = (0..width * height)
        .map(|i| {
            Rgb(
                level(planes[0][i]),
                level(planes[1][i]),
                level(planes[2][i]),
            )
        })
        .collect();
    Pixels { width, height, rgb }
}

fn ppm(pixels: &Pixels) -> Vec<u8> {
    let mut out = format!("P6\n{} {}\n255\n", pixels.width, pixels.height).into_bytes();
    out.reserve(pixels.rgb.len() * 3);
    for p in &pixels.rgb {
        out.extend([p.0, p.1, p.2]);
    }
    out
}

/// The mean of a disc of `radius` around each pixel, the picture's edge
/// pixels standing in for what lies past it (as the lock's texture did). Each
/// row of the disc is a run of a row, summed from that row's running sums;
/// its ends count by how far the circle crosses them, so a radius between
/// two whole pixels draws a round disc, not a stepped one.
fn disc(plane: &[f32], width: usize, height: usize, radius: f32) -> Vec<f32> {
    let reach = radius.ceil() as usize;
    // Each row's running sums, the row reaching `reach` + 1 past either end.
    let pad = reach + 1;
    let span = width + 2 * pad;
    let mut sums = vec![0f64; height * (span + 1)];
    for y in 0..height {
        let row = &plane[y * width..(y + 1) * width];
        let at = |x: usize| row[x.saturating_sub(pad).min(width - 1)];
        let base = y * (span + 1);
        for x in 0..span {
            sums[base + x + 1] = sums[base + x] + f64::from(at(x));
        }
    }
    // Run lengths and end weights for each row of the disc.
    let rows: Vec<(isize, usize, f64)> = (-(reach as isize)..=reach as isize)
        .filter_map(|dy| {
            let half = (radius * radius - (dy * dy) as f32).max(0.0).sqrt();
            if half <= 0.0 && dy != 0 {
                return None;
            }
            let whole = half.floor();
            Some((dy, whole as usize, f64::from(half - whole)))
        })
        .collect();
    let weight: f64 = rows
        .iter()
        .map(|&(_, w, f)| (2 * w + 1) as f64 + 2.0 * f)
        .sum();
    let mut out = vec![0f32; width * height];
    for y in 0..height {
        for x in 0..width {
            let mut total = 0.0;
            for &(dy, whole, fraction) in &rows {
                let row = (y as isize + dy).clamp(0, height as isize - 1) as usize;
                let base = row * (span + 1);
                let centre = x + pad;
                let run = sums[base + centre + whole + 1] - sums[base + centre - whole];
                let ends = if fraction > 0.0 {
                    (sums[base + centre - whole] - sums[base + centre - whole - 1])
                        + (sums[base + centre + whole + 2] - sums[base + centre + whole + 1])
                } else {
                    0.0
                };
                total += run + fraction * ends;
            }
            out[y * width + x] = (total / weight) as f32;
        }
    }
    out
}

/// A Gaussian of `sigma`, as three box blurs each way (the widths of
/// Kovesi's "Fast almost-Gaussian filtering"), the edge pixels standing in
/// for what lies past the edge.
fn gaussian(plane: &mut [f32], width: usize, height: usize, sigma: f32) {
    if sigma < 0.5 {
        return;
    }
    let n = 3.0f32;
    let ideal = (12.0 * sigma * sigma / n + 1.0).sqrt();
    let mut lower = ideal.floor() as i32;
    if lower % 2 == 0 {
        lower -= 1;
    }
    let lower_f = lower as f32;
    let m = ((12.0 * sigma * sigma - n * lower_f * lower_f - 4.0 * n * lower_f - 3.0 * n)
        / (-4.0 * lower_f - 4.0))
        .round() as i32;
    for pass in 0..3 {
        let size = if pass < m { lower } else { lower + 2 };
        let half = (size.max(1) as usize - 1) / 2;
        box_pass(plane, width, height, half, true);
        box_pass(plane, width, height, half, false);
    }
}

/// One box blur of `half` pixels each side, along the rows or the columns.
fn box_pass(plane: &mut [f32], width: usize, height: usize, half: usize, rows: bool) {
    if half == 0 {
        return;
    }
    let (lines, length, step, stride) = if rows {
        (height, width, 1, width)
    } else {
        (width, height, width, 1)
    };
    let size = (2 * half + 1) as f64;
    let mut line = vec![0f32; length];
    for l in 0..lines {
        let start = l * stride;
        for (i, v) in line.iter_mut().enumerate() {
            *v = plane[start + i * step];
        }
        let at = |i: isize| line[i.clamp(0, length as isize - 1) as usize];
        let mut sum: f64 = (-(half as isize)..=half as isize)
            .map(|i| f64::from(at(i)))
            .sum();
        for i in 0..length {
            plane[start + i * step] = (sum / size) as f32;
            let i = i as isize;
            sum += f64::from(at(i + half as isize + 1)) - f64::from(at(i - half as isize));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn picture(width: usize, height: usize, at: impl Fn(usize, usize) -> u8) -> Pixels {
        let rgb = (0..width * height)
            .map(|i| {
                let v = at(i % width, i / width);
                Rgb(v, v, v)
            })
            .collect();
        Pixels { width, height, rgb }
    }

    fn grey(p: &Pixels, x: usize, y: usize) -> u8 {
        p.rgb[y * p.width + x].0
    }

    #[test]
    fn a_flat_picture_stays_flat_with_its_contrast_taken_down() {
        let black = blur(&picture(64, 40, |_, _| 0));
        let white = blur(&picture(64, 40, |_, _| 255));
        // MultiEffect's -0.08: black 10, white 245, as the lock showed them.
        assert!(black.rgb.iter().all(|p| *p == Rgb(10, 10, 10)));
        assert!(white.rgb.iter().all(|p| *p == Rgb(245, 245, 245)));
    }

    #[test]
    fn an_edge_spreads_as_the_lock_spread_it() {
        // A 16:10 picture as wide as a P1's screen, scaled down to the
        // backdrop's size: black on the left, white on the right.
        let (w, h) = (384, 240);
        let out = blur(&picture(w, h, |x, _| if x < w / 2 { 0 } else { 255 }));
        let level = |x: usize| (f32::from(grey(&out, x, h / 2)) - 10.0) / 235.0;
        // Halfway at the edge, and the measured spread of the old lock at
        // 40 and 120 of its 3840 pixels from it (0.37 and 0.13, 0.63 and
        // 0.87), within two levels of 255.
        let px = |screen: f32| (screen / 3840.0 * w as f32).round() as usize;
        assert!((level(w / 2) - 0.5).abs() < 0.03, "{}", level(w / 2));
        for (offset, want) in [(40.0, 0.37), (120.0, 0.13)] {
            let below = level(w / 2 - px(offset));
            let above = level(w / 2 + px(offset));
            assert!(
                (below - want).abs() < 2.0 / 235.0 + 0.02,
                "{offset}: {below} vs {want}"
            );
            assert!(
                (above - (1.0 - want)).abs() < 2.0 / 235.0 + 0.02,
                "{offset}: {above} vs {}",
                1.0 - want
            );
        }
        // Past the disc and its softening, nothing of the other side.
        assert_eq!(grey(&out, w / 2 - px(300.0), h / 2), 10);
        assert_eq!(grey(&out, w / 2 + px(300.0), h / 2), 245);
    }

    #[test]
    fn a_point_spreads_round() {
        // A small bright square's spread reaches as far along the diagonal
        // as along the axes: a disc, not a square.
        let (w, h) = (384, 240);
        let bright = blur(&picture(w, h, |x, y| {
            if (x as isize - w as isize / 2).abs() <= 2 && (y as isize - h as isize / 2).abs() <= 2
            {
                255
            } else {
                0
            }
        }));
        let reach = |dx: f32, dy: f32| {
            (1..100)
                .find(|&r| {
                    let x = (w as f32 / 2.0 + dx * r as f32).round() as usize;
                    let y = (h as f32 / 2.0 + dy * r as f32).round() as usize;
                    x >= w || y >= h || grey(&bright, x, y) <= 10
                })
                .unwrap_or(100) as f32
        };
        let axis = reach(1.0, 0.0);
        let diagonal = reach(
            std::f32::consts::FRAC_1_SQRT_2,
            std::f32::consts::FRAC_1_SQRT_2,
        );
        assert!(
            (diagonal - axis).abs() <= 2.0,
            "axis {axis}, diagonal {diagonal}"
        );
    }

    #[test]
    fn edges_hold_their_colour() {
        // White to the left edge stays white there: the picture's edge
        // stands in for what lies past it, as the lock's texture had it.
        let out = blur(&picture(96, 60, |x, _| if x < 48 { 255 } else { 0 }));
        assert_eq!(grey(&out, 0, 0), 245);
        assert_eq!(grey(&out, 0, 59), 245);
        assert_eq!(grey(&out, 95, 30), 10);
    }

    #[test]
    fn the_file_is_a_ppm_qt_reads() {
        let bytes = ppm(&picture(2, 1, |x, _| x as u8 * 255));
        assert_eq!(&bytes[..11], b"P6\n2 1\n255\n");
        assert_eq!(&bytes[11..], &[0, 0, 0, 255, 255, 255]);
    }
}
