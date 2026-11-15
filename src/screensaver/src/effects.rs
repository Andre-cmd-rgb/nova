//! The effects: six ways for a text to come onto a black screen, stay a
//! while and leave it.
//!
//! An effect draws the frame for a moment, from that moment alone: nothing is
//! carried from one frame to the next. So a frame that comes late is simply
//! the right one for its time, and a test can ask for any moment.

use std::f64::consts::{PI, TAU};

use crate::canvas::Canvas;
use crate::color::{Rgb, WHITE};
use crate::rng::{noise, pick, Rng};
use crate::text::Text;

/// A terminal's cell is about twice as tall as it is wide: a distance down
/// counts double, and a circle is drawn half as high as it is wide.
const ASPECT: f64 = 2.0;
/// How far a row leans the text's gradient and its sweeps, in columns.
const SLANT: f64 = 1.5;
/// How long the text stays between coming and going.
const HOLD: f64 = 4.5;

const STARS: [char; 4] = ['·', '•', '*', '+'];
const SHADES: [char; 3] = ['░', '▒', '▓'];
const GRAIN: [char; 8] = ['░', '▒', '▓', '▚', '▞', '▖', '▗', '▘'];
const WARM: Rgb = Rgb(255, 196, 120);
const EMBER: Rgb = Rgb(190, 64, 28);

/// A character of the text at its place on the screen.
pub struct Cell {
    pub x: i32,
    pub y: i32,
    pub ch: char,
    /// Where it lies from the text's top left, 0, to its bottom right, 1.
    across: f64,
    /// Four numbers of chance, from 0 to 1, its own for this run.
    chance: [f64; 4],
}

/// The text centred on a screen, in two colors, with this run's chance.
pub struct Scene {
    pub cols: i32,
    pub rows: i32,
    pub cells: Vec<Cell>,
    left: i32,
    top: i32,
    width: i32,
    height: i32,
    first: Rgb,
    second: Rgb,
    seed: u64,
}

impl Scene {
    pub fn new(text: &Text, cols: i32, rows: i32, colors: (Rgb, Rgb), seed: u64) -> Scene {
        let (left, top) = ((cols - text.width) / 2, (rows - text.height) / 2);
        let span = f64::from((text.width - 1).max(0)) + f64::from((text.height - 1).max(0)) * SLANT;
        let mut rng = Rng::new(seed);
        let cells = text
            .glyphs
            .iter()
            .map(|glyph| Cell {
                x: left + glyph.x,
                y: top + glyph.y,
                ch: glyph.ch,
                across: if span > 0.0 {
                    (f64::from(glyph.x) + f64::from(glyph.y) * SLANT) / span
                } else {
                    0.5
                },
                chance: std::array::from_fn(|_| rng.unit()),
            })
            .collect();
        Scene {
            cols,
            rows,
            cells,
            left,
            top,
            width: text.width,
            height: text.height,
            first: colors.0,
            second: colors.1,
            seed,
        }
    }

    /// A cell's own color: the first at the text's top left, the second at its
    /// bottom right, the two drifting slowly through it.
    fn tint(&self, cell: &Cell, t: f64) -> Rgb {
        self.first
            .mix(self.second, cell.across + 0.12 * (t * 0.5).sin())
    }

    /// The same while the text stays, `since` seconds in: a band of light
    /// crosses it every few seconds, so it is never still.
    fn held(&self, cell: &Cell, t: f64, since: f64) -> Rgb {
        let band = (since / 3.4).fract() * 1.5 - 0.25;
        let near = 1.0 - ((cell.across - band).abs() / 0.11).min(1.0);
        self.tint(cell, t).mix(WHITE, near * near * 0.65)
    }

    /// The color of a cell that has arrived: its tint while the rest still
    /// comes, the held one after.
    fn settled(&self, cell: &Cell, t: f64, intro: f64) -> Rgb {
        if t < intro {
            self.tint(cell, t)
        } else {
            self.held(cell, t, t - intro)
        }
    }

    /// How far across the text a column is, from 0 to 1.
    fn column(&self, cell: &Cell) -> f64 {
        f64::from(cell.x - self.left) / f64::from((self.width - 1).max(1))
    }

    /// How high in the text a row is: 0 the bottom one, 1 the top.
    fn height_of(&self, cell: &Cell) -> f64 {
        f64::from(self.top + self.height - 1 - cell.y) / f64::from((self.height - 1).max(1))
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Effect {
    /// Stars from all over the screen come together into the text, and fly
    /// apart from its middle.
    Gather,
    /// Light sweeps the text in from one corner, and out again.
    Dawn,
    /// The text falls into place from above, and drops off the screen.
    Rain,
    /// It catches fire from the bottom up, throws sparks and cools to embers.
    Ignite,
    /// A wave spreads from the text's first character and lights what it
    /// passes; another closes in and puts it out.
    Ripple,
    /// Noise that clears into the text, and takes it back.
    Resolve,
}

impl Effect {
    pub const ALL: [Effect; 6] = [
        Effect::Gather,
        Effect::Dawn,
        Effect::Rain,
        Effect::Ignite,
        Effect::Ripple,
        Effect::Resolve,
    ];

    pub fn name(self) -> &'static str {
        match self {
            Effect::Gather => "gather",
            Effect::Dawn => "dawn",
            Effect::Rain => "rain",
            Effect::Ignite => "ignite",
            Effect::Ripple => "ripple",
            Effect::Resolve => "resolve",
        }
    }

    pub fn named(name: &str) -> Option<Effect> {
        Effect::ALL.into_iter().find(|effect| effect.name() == name)
    }

    /// How long the text takes to come, and to go.
    fn ends(self) -> (f64, f64) {
        match self {
            Effect::Gather => (3.0, 1.6),
            Effect::Dawn => (2.8, 2.4),
            Effect::Rain => (3.2, 1.9),
            Effect::Ignite => (2.8, 2.7),
            Effect::Ripple => (2.6, 1.9),
            Effect::Resolve => (3.2, 2.2),
        }
    }

    /// From the first frame to the screen being black again.
    pub fn length(self) -> f64 {
        let (intro, outro) = self.ends();
        intro + HOLD + outro
    }

    /// When the whole text is there, to the moment it starts to go.
    #[cfg(test)]
    fn held(self) -> (f64, f64) {
        let (intro, _) = self.ends();
        (intro, intro + HOLD)
    }

    /// The frame `t` seconds in, onto an empty canvas.
    pub fn draw(self, scene: &Scene, t: f64, canvas: &mut Canvas) {
        let (intro, outro) = self.ends();
        let stage = Stage {
            t,
            intro,
            leaving: t - intro - HOLD,
            outro,
        };
        match self {
            Effect::Gather => gather(scene, &stage, canvas),
            Effect::Dawn => dawn(scene, &stage, canvas),
            Effect::Rain => rain(scene, &stage, canvas),
            Effect::Ignite => ignite(scene, &stage, canvas),
            Effect::Ripple => ripple(scene, &stage, canvas),
            Effect::Resolve => resolve(scene, &stage, canvas),
        }
    }
}

/// Where in an effect a frame is.
struct Stage {
    /// Seconds since the effect began.
    t: f64,
    /// How long the text takes to come.
    intro: f64,
    /// Seconds since the text began to go; negative until it does.
    leaving: f64,
    /// How long it takes to go.
    outro: f64,
}

impl Stage {
    fn is_leaving(&self) -> bool {
        self.leaving >= 0.0
    }
}

/// How much of `long` seconds has passed since `from`, from 0 to 1.
fn part(t: f64, from: f64, long: f64) -> f64 {
    ((t - from) / long).clamp(0.0, 1.0)
}

fn ease_in(p: f64) -> f64 {
    p * p * p
}

fn ease_both(p: f64) -> f64 {
    if p < 0.5 {
        4.0 * p * p * p
    } else {
        1.0 - (2.0 - 2.0 * p).powi(3) / 2.0
    }
}

/// A full block comes and goes through the three shades, `amount` from 0 to
/// 1; any other character is itself from the start.
fn shade(ch: char, amount: f64) -> char {
    if ch != '█' || amount >= 1.0 {
        ch
    } else {
        SHADES[((amount.max(0.0) * 3.0) as usize).min(2)]
    }
}

fn place(canvas: &mut Canvas, x: f64, y: f64, ch: char, color: Rgb) {
    canvas.put(x.round() as i32, y.round() as i32, ch, color);
}

fn gather(scene: &Scene, stage: &Stage, canvas: &mut Canvas) {
    const TRAVEL: f64 = 1.6;
    let t = stage.t;
    sky(scene, stage, canvas);
    let (middle_x, middle_y) = (
        f64::from(scene.left) + f64::from(scene.width - 1) / 2.0,
        f64::from(scene.top) + f64::from(scene.height - 1) / 2.0,
    );
    for (i, cell) in scene.cells.iter().enumerate() {
        let [a, b, c, d] = cell.chance;
        let star = STARS[((d * STARS.len() as f64) as usize).min(STARS.len() - 1)];
        let (home_x, home_y) = (f64::from(cell.x), f64::from(cell.y));
        let tint = scene.tint(cell, t);
        if stage.is_leaving() {
            // Away from the middle of the text, faster and faster.
            let p = part(stage.leaving, c * 0.35, 1.15);
            if p >= 1.0 {
                continue;
            }
            let (mut dx, mut dy) = (home_x - middle_x, (home_y - middle_y) * ASPECT);
            let far = dx.hypot(dy);
            if far < 0.5 {
                (dx, dy) = ((a * TAU).cos(), (a * TAU).sin());
            } else {
                (dx, dy) = (dx / far, dy / far);
            }
            let reach = ease_in(p) * f64::from(scene.cols.max(scene.rows * 2));
            let color = tint
                .mix(WHITE, (p * 4.0).min(1.0) * 0.6)
                .dim(1.0 - p * 0.85);
            let glyph = if p < 0.12 { cell.ch } else { star };
            place(
                canvas,
                home_x + dx * reach,
                home_y + dy * reach / ASPECT,
                glyph,
                color,
            );
            continue;
        }
        let (start_x, start_y) = (a * f64::from(scene.cols), b * f64::from(scene.rows));
        let leaves = c * 1.2;
        let p = part(t, leaves, TRAVEL);
        if p <= 0.0 {
            // Not on its way yet: a star that twinkles where it waits.
            let twinkle = 0.25 + 0.35 * noise(scene.seed, i as u64, (t * 6.0) as u64);
            place(canvas, start_x, start_y, star, tint.dim(twinkle));
        } else if p < 1.0 {
            // On a bowed path, as a star until it is nearly home.
            let e = ease_both(p);
            let (dx, dy) = (home_x - start_x, home_y - start_y);
            let bow = (d - 0.5) * 0.5 * (PI * e).sin();
            let x = start_x + dx * e - dy * ASPECT * bow;
            let y = start_y + dy * e + dx / ASPECT * bow;
            place(
                canvas,
                x,
                y,
                if p > 0.9 { cell.ch } else { star },
                tint.dim(0.45 + 0.55 * e),
            );
        } else {
            let flash = 1.0 - part(t, leaves + TRAVEL, 0.4);
            canvas.put(
                cell.x,
                cell.y,
                cell.ch,
                scene.settled(cell, t, stage.intro).mix(WHITE, flash * 0.9),
            );
        }
    }
}

/// A few faint stars behind the text, there from soon after the start to
/// shortly before the end.
fn sky(scene: &Scene, stage: &Stage, canvas: &mut Canvas) {
    if scene.cols <= 0 || scene.rows <= 0 {
        return;
    }
    let count = (scene.cols * scene.rows / 150).clamp(8, 90) as u64;
    let shown = part(stage.t, 0.0, 0.6).min(1.0 - part(stage.leaving, stage.outro - 0.7, 0.6));
    for j in 0..count {
        let x = (pick(scene.seed, 901, j) % scene.cols as u64) as i32;
        let y = (pick(scene.seed, 902, j) % scene.rows as u64) as i32;
        let twinkle = noise(scene.seed, 903 + j, (stage.t * 3.0) as u64);
        let bright = (0.08 + 0.2 * twinkle) * shown;
        if bright > 0.02 {
            canvas.put(x, y, '·', WHITE.dim(bright));
        }
    }
}

fn dawn(scene: &Scene, stage: &Stage, canvas: &mut Canvas) {
    // The width of the band of light, as a share of the way across the text.
    const BAND: f64 = 0.2;
    let t = stage.t;
    // The front of the band, from before the text to past it.
    // At an even pace: a sweep that hurries through its middle is over
    // before it is seen.
    let front = |p: f64| p * (1.0 + 3.0 * BAND) - BAND;
    for cell in &scene.cells {
        // Each cell a little off the line, so the edge is not ruled.
        let at = cell.across + (cell.chance[0] - 0.5) * 0.04;
        if stage.is_leaving() {
            let gone = (front(part(stage.leaving, 0.0, stage.outro)) - at) / BAND;
            if gone >= 1.0 {
                continue;
            }
            let held = scene.held(cell, t, t - stage.intro);
            let color = if gone <= 0.0 {
                held
            } else {
                held.mix(WHITE, 0.5 * (1.0 - gone)).dim(1.0 - gone)
            };
            canvas.put(cell.x, cell.y, shade(cell.ch, 1.0 - gone.max(0.0)), color);
        } else {
            let lit = (front(part(t, 0.0, stage.intro)) - at) / BAND;
            if lit <= 0.0 {
                continue;
            }
            let color = scene
                .settled(cell, t, stage.intro)
                .mix(WHITE, (1.0 - lit).clamp(0.0, 1.0) * 0.9);
            canvas.put(cell.x, cell.y, shade(cell.ch, lit), color);
        }
    }
}

fn rain(scene: &Scene, stage: &Stage, canvas: &mut Canvas) {
    const FALL: f64 = 0.9;
    let t = stage.t;
    for cell in &scene.cells {
        let [a, b, c, _] = cell.chance;
        let home = f64::from(cell.y);
        // The bottom row is the first to come, and the first to go.
        let low = 1.0 - scene.height_of(cell);
        if stage.is_leaving() {
            let p = part(stage.leaving, (1.0 - low) * 0.7 + c * 0.3, 0.8);
            if p >= 1.0 {
                continue;
            }
            let y = home + (f64::from(scene.rows) - home + 2.0) * p * p;
            let color = scene.held(cell, t, t - stage.intro).dim(1.0 - p * 0.6);
            place(canvas, f64::from(cell.x), y, cell.ch, color);
            continue;
        }
        let starts = scene.column(cell) * 1.3 + a * 0.3 + (1.0 - low) * 0.5;
        let p = part(t, starts, FALL);
        if p <= 0.0 {
            continue;
        }
        if p < 1.0 {
            // From above the screen, faster as it falls, with a short tail.
            let from = -1.0 - b * 5.0;
            let row = (from + (home - from) * p * p).round() as i32;
            let tint = scene.tint(cell, t);
            canvas.put(cell.x, row - 2, cell.ch, tint.dim(0.15));
            canvas.put(cell.x, row - 1, cell.ch, tint.dim(0.35));
            canvas.put(cell.x, row, cell.ch, tint);
        } else {
            let flash = 1.0 - part(t, starts + FALL, 0.3);
            canvas.put(
                cell.x,
                cell.y,
                cell.ch,
                scene.settled(cell, t, stage.intro).mix(WHITE, flash * 0.8),
            );
        }
    }
}

fn ignite(scene: &Scene, stage: &Stage, canvas: &mut Canvas) {
    let t = stage.t;
    // When a cell catches: the bottom row first.
    let catches = |cell: &Cell| scene.height_of(cell) * 1.5 + cell.chance[0] * 0.5;
    for (i, cell) in scene.cells.iter().enumerate() {
        let caught = catches(cell);
        if t < caught {
            continue;
        }
        let flicker = 0.9 + 0.1 * noise(scene.seed, i as u64, (t * 12.0) as u64);
        if stage.is_leaving() {
            // It cools from the top row down, to embers and out.
            let p = part(
                stage.leaving,
                (1.0 - scene.height_of(cell)) * 1.2 + cell.chance[1] * 0.5,
                0.9,
            );
            if p >= 1.0 {
                continue;
            }
            let color = scene
                .held(cell, t, t - stage.intro)
                .mix(EMBER, p)
                .dim(flicker * (1.0 - p * 0.75));
            canvas.put(cell.x, cell.y, shade(cell.ch, (1.0 - p) * 3.0), color);
        } else {
            let age = t - caught;
            let heat = (-age * 2.2).exp();
            let color = scene
                .settled(cell, t, stage.intro)
                .mix(WARM, heat)
                .mix(WHITE, heat * heat)
                .dim(flicker);
            canvas.put(cell.x, cell.y, shade(cell.ch, age / 0.2), color);
        }
    }
    // Sparks rise from cells that burn, each once, and never over the text.
    let alight = stage.intro + HOLD;
    for j in 0..(scene.cells.len() / 5) as u64 {
        let source = &scene.cells[(pick(scene.seed, 77, j) % scene.cells.len() as u64) as usize];
        let born = 0.3 + noise(scene.seed, 78, j) * (alight - 1.0);
        let age = t - born;
        if !(0.0..0.9).contains(&age) || born < catches(source) {
            continue;
        }
        let x = (f64::from(source.x) + (age * 7.0 + noise(scene.seed, 79, j) * TAU).sin() * 1.3)
            .round() as i32;
        let y = (f64::from(source.y) - 1.0 - age * 7.0).round() as i32;
        if canvas.get(x, y).is_none() {
            canvas.put(
                x,
                y,
                if age < 0.45 { '*' } else { '·' },
                WARM.dim(1.0 - age / 0.9),
            );
        }
    }
}

fn ripple(scene: &Scene, stage: &Stage, canvas: &mut Canvas) {
    let t = stage.t;
    // From the text's first character: the tip of the wordmark's star.
    let Some(origin) = scene.cells.first() else {
        return;
    };
    // How far a cell is from there, each a little off, so the wave's edge is
    // not drawn with a compass.
    let far = |cell: &Cell| {
        (f64::from(cell.x - origin.x).hypot(f64::from(cell.y - origin.y) * ASPECT)
            + (cell.chance[0] - 0.5) * 1.2)
            .max(0.0)
    };
    let reach = scene.cells.iter().map(far).fold(0.0, f64::max) + 3.0;
    if stage.is_leaving() {
        // A circle closes in on where it began, and what is outside goes dark.
        let p = part(stage.leaving, 0.0, 1.3);
        let edge = (reach + 2.0) * (1.0 - p * p) - 2.0;
        for cell in &scene.cells {
            let outside = far(cell) - edge;
            if outside >= 2.0 {
                continue;
            }
            let tint = scene.tint(cell, t);
            let left = 1.0 - outside.max(0.0) / 2.0;
            let color = if outside <= 0.0 {
                tint
            } else {
                tint.mix(WHITE, 0.7).dim(left)
            };
            canvas.put(cell.x, cell.y, shade(cell.ch, left), color);
        }
        // The last of it: a point of light at the origin.
        let glow = 1.0 - part(stage.leaving, 1.2, 0.5);
        if stage.leaving >= 1.2 && glow > 0.0 {
            canvas.put(
                origin.x,
                origin.y,
                if glow > 0.5 { '*' } else { '·' },
                WHITE.dim(glow),
            );
        }
        return;
    }
    // The wave spreads at an even pace, and runs on past the text as a ring.
    let p = part(t, 0.0, stage.intro);
    let front = reach * 1.35 * p;
    if p < 1.0 {
        let dots = ((front * 3.0) as usize).clamp(12, 160);
        for k in 0..dots {
            let angle = k as f64 / dots as f64 * TAU;
            let (x, y) = (
                f64::from(origin.x) + angle.cos() * front,
                f64::from(origin.y) + angle.sin() * front / ASPECT,
            );
            place(canvas, x, y, '·', WHITE.dim(0.55 * (1.0 - p)));
        }
    }
    for cell in &scene.cells {
        let distance = far(cell);
        let behind = front - distance;
        if behind < 0.0 {
            continue;
        }
        // While the text stays, a fainter wave runs out through it again and
        // again.
        let pulse = if t < stage.intro {
            0.0
        } else {
            let wave = ((t - stage.intro) / 1.6).fract() * (reach + 4.0);
            1.0 - ((distance - wave).abs() / 2.0).min(1.0)
        };
        let glare = ((1.0 - behind / 5.0).max(0.0) * 0.9).max(pulse * 0.6);
        canvas.put(
            cell.x,
            cell.y,
            shade(cell.ch, behind / 2.5),
            scene.tint(cell, t).mix(WHITE, glare),
        );
    }
}

fn resolve(scene: &Scene, stage: &Stage, canvas: &mut Canvas) {
    let t = stage.t;
    let tick = (t * 14.0) as u64;
    for (i, cell) in scene.cells.iter().enumerate() {
        let [a, b, _, _] = cell.chance;
        let grain = GRAIN[(pick(scene.seed, i as u64, tick) % GRAIN.len() as u64) as usize];
        let seen = noise(scene.seed ^ 1, i as u64, tick);
        let dust = scene.tint(cell, t).dim(0.4);
        if stage.is_leaving() {
            // The right of the text is taken back first.
            let goes = (1.0 - scene.column(cell)) * 0.7 + b * 0.9;
            if stage.leaving < goes {
                canvas.put(
                    cell.x,
                    cell.y,
                    cell.ch,
                    scene.held(cell, t, t - stage.intro),
                );
            } else {
                let p = part(stage.leaving, goes, 0.5);
                if p < 1.0 && seen > p {
                    canvas.put(cell.x, cell.y, grain, dust.dim(1.0 - p * 0.5));
                }
            }
            continue;
        }
        // The left comes clear first; until a cell does, noise shows in it
        // more and more often.
        let clears = 0.5 + scene.column(cell) * 1.5 + a * 0.8;
        if t < clears {
            if seen < 0.15 + 0.6 * (t / clears) {
                canvas.put(cell.x, cell.y, grain, dust);
            }
        } else {
            let flash = 1.0 - part(t, clears, 0.35);
            canvas.put(
                cell.x,
                cell.y,
                cell.ch,
                scene.settled(cell, t, stage.intro).mix(WHITE, flash * 0.85),
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const WORDMARK: &str = include_str!("../../../theme/wordmark/nova.txt");

    fn scene(text: &str, cols: i32, rows: i32, seed: u64) -> Scene {
        Scene::new(
            &Text::parse(text),
            cols,
            rows,
            (Rgb(203, 166, 255), Rgb(18, 191, 244)),
            seed,
        )
    }

    fn frame(effect: Effect, scene: &Scene, t: f64) -> Canvas {
        let mut canvas = Canvas::new(scene.cols, scene.rows);
        effect.draw(scene, t, &mut canvas);
        canvas
    }

    #[test]
    fn every_effect_has_a_name_of_its_own_and_is_found_by_it() {
        for effect in Effect::ALL {
            assert_eq!(Effect::named(effect.name()), Some(effect));
        }
        assert_eq!(Effect::named("beams"), None);
    }

    #[test]
    fn the_text_is_centred_on_the_screen() {
        let scene = scene(WORDMARK, 120, 40, 1);
        let (left, right) = (
            scene.cells.iter().map(|c| c.x).min().unwrap(),
            scene.cells.iter().map(|c| c.x).max().unwrap(),
        );
        let (top, bottom) = (
            scene.cells.iter().map(|c| c.y).min().unwrap(),
            scene.cells.iter().map(|c| c.y).max().unwrap(),
        );
        assert!(
            (left - (119 - right)).abs() <= 1,
            "{left} columns to its left, {} to its right",
            119 - right
        );
        assert!((top - (39 - bottom)).abs() <= 1);
        assert!(left > 0 && top > 0);
    }

    #[test]
    fn while_it_stays_the_whole_text_is_there_and_each_character_in_its_place() {
        for effect in Effect::ALL {
            for seed in 1..=6 {
                let scene = scene(WORDMARK, 110, 36, seed);
                let (from, to) = effect.held();
                for t in [from, from + 0.01, (from + to) / 2.0, to - 0.02] {
                    let canvas = frame(effect, &scene, t);
                    for cell in &scene.cells {
                        let shown = canvas.get(cell.x, cell.y).map(|(ch, _)| ch);
                        assert_eq!(
                            shown,
                            Some(cell.ch),
                            "{} at {t:.2}s, seed {seed}, cell {},{}",
                            effect.name(),
                            cell.x,
                            cell.y
                        );
                    }
                }
            }
        }
    }

    #[test]
    fn it_begins_and_ends_on_a_black_screen() {
        for effect in Effect::ALL {
            for seed in 1..=6 {
                let scene = scene(WORDMARK, 110, 36, seed);
                // At the start hardly anything of the text is in its place yet.
                let first = frame(effect, &scene, 0.0);
                let home = scene
                    .cells
                    .iter()
                    .filter(|c| first.get(c.x, c.y).map(|(ch, _)| ch) == Some(c.ch))
                    .count();
                assert!(
                    home * 20 < scene.cells.len(),
                    "{}: {home} cells at home at the start",
                    effect.name()
                );
                for after in [0.0, 0.3, 5.0] {
                    assert!(
                        frame(effect, &scene, effect.length() + after).is_empty(),
                        "{} leaves something behind",
                        effect.name()
                    );
                }
            }
        }
    }

    #[test]
    fn a_frame_depends_only_on_its_moment_and_the_seed() {
        for effect in Effect::ALL {
            let (a, b) = (scene(WORDMARK, 100, 30, 9), scene(WORDMARK, 100, 30, 9));
            for step in 0..40 {
                let t = effect.length() * f64::from(step) / 40.0;
                assert!(frame(effect, &a, t) == frame(effect, &b, t));
            }
            let other = scene(WORDMARK, 100, 30, 10);
            assert!(
                frame(effect, &a, 1.0) != frame(effect, &other, 1.0),
                "{} ignores its seed",
                effect.name()
            );
        }
    }

    #[test]
    fn any_screen_and_any_text_can_be_drawn() {
        let texts = [
            WORDMARK,
            "",
            "x",
            "one line of plain words",
            "a\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\nb",
        ];
        for effect in Effect::ALL {
            for text in texts {
                for (cols, rows) in [(200, 60), (42, 11), (30, 8), (5, 2), (1, 1), (0, 0)] {
                    let scene = scene(text, cols, rows, 3);
                    for step in 0..=60 {
                        frame(
                            effect,
                            &scene,
                            (effect.length() + 1.0) * f64::from(step) / 60.0,
                        );
                    }
                }
            }
        }
    }

    #[test]
    fn colors_run_from_the_first_at_the_top_left_to_the_second_at_the_bottom_right() {
        let scene = scene("ab\ncd", 20, 10, 1);
        let corner = |x, y| {
            scene
                .cells
                .iter()
                .find(|c| (c.x, c.y) == (scene.left + x, scene.top + y))
                .unwrap()
        };
        assert_eq!(corner(0, 0).across, 0.0);
        assert_eq!(corner(1, 1).across, 1.0);
        assert_eq!(scene.tint(corner(0, 0), 0.0), Rgb(203, 166, 255));
        assert_eq!(scene.tint(corner(1, 1), 0.0), Rgb(18, 191, 244));
    }

    #[test]
    fn a_full_block_comes_through_the_shades_and_other_characters_do_not() {
        assert_eq!(shade('█', 0.0), '░');
        assert_eq!(shade('█', 0.5), '▒');
        assert_eq!(shade('█', 0.99), '▓');
        assert_eq!(shade('█', 1.0), '█');
        assert_eq!(shade('█', -3.0), '░');
        assert_eq!(shade('n', 0.1), 'n');
        assert_eq!(shade('▀', 0.1), '▀');
    }
}
