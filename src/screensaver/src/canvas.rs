//! One frame, cell by cell, and the fewest bytes that turn the terminal from
//! the last frame into it.

use std::fmt::Write;

use crate::color::Rgb;

#[derive(Clone, PartialEq)]
pub struct Canvas {
    pub cols: i32,
    pub rows: i32,
    cells: Vec<Option<(char, Rgb)>>,
}

impl Canvas {
    pub fn new(cols: i32, rows: i32) -> Canvas {
        let (cols, rows) = (cols.max(0), rows.max(0));
        Canvas {
            cols,
            rows,
            cells: vec![None; (cols * rows) as usize],
        }
    }

    pub fn clear(&mut self) {
        self.cells.fill(None);
    }

    /// A character at a column and row; one off the screen is not drawn, and a
    /// later one in the same cell takes its place.
    pub fn put(&mut self, x: i32, y: i32, ch: char, color: Rgb) {
        if (0..self.cols).contains(&x) && (0..self.rows).contains(&y) {
            self.cells[(y * self.cols + x) as usize] = Some((ch, color));
        }
    }

    pub fn get(&self, x: i32, y: i32) -> Option<(char, Rgb)> {
        if (0..self.cols).contains(&x) && (0..self.rows).contains(&y) {
            self.cells[(y * self.cols + x) as usize]
        } else {
            None
        }
    }

    #[cfg(test)]
    pub fn is_empty(&self) -> bool {
        self.cells.iter().all(Option::is_none)
    }

    /// The frame as plain text, a line for each row.
    pub fn text(&self) -> String {
        let mut text = String::new();
        for y in 0..self.rows {
            let line: String = (0..self.cols)
                .map(|x| self.get(x, y).map_or(' ', |(ch, _)| ch))
                .collect();
            text.push_str(line.trim_end());
            text.push('\n');
        }
        text
    }
}

/// What the terminal is sent to show `next` where it shows `last`: only the
/// cells that differ, the cursor moved only when it is not already there and
/// the color named only when it changes. Both frames are the same size. The
/// terminal draws it in one go (synchronized output), so no frame is seen half
/// drawn.
pub fn paint(last: &Canvas, next: &Canvas, out: &mut String) {
    debug_assert_eq!((last.cols, last.rows), (next.cols, next.rows));
    let begun = out.len();
    out.push_str("\x1b[?2026h");
    let body = out.len();
    let mut cursor = None;
    let mut ink = None;
    for y in 0..next.rows {
        for x in 0..next.cols {
            let cell = next.get(x, y);
            if cell == last.get(x, y) {
                continue;
            }
            if cursor != Some((x, y)) {
                let _ = write!(out, "\x1b[{};{}H", y + 1, x + 1);
            }
            match cell {
                Some((ch, color)) => {
                    if ink != Some(color) {
                        let _ = write!(out, "\x1b[38;2;{};{};{}m", color.0, color.1, color.2);
                        ink = Some(color);
                    }
                    out.push(ch);
                }
                None => out.push(' '),
            }
            // The last column leaves the cursor where terminals disagree.
            cursor = (x + 1 < next.cols).then_some((x + 1, y));
        }
    }
    if out.len() == body {
        out.truncate(begun);
    } else {
        out.push_str("\x1b[?2026l");
    }
}

#[cfg(test)]
pub mod tests {
    use super::*;
    use crate::rng::Rng;

    /// A terminal that understands what `paint` writes, and nothing more.
    pub fn show(screen: &mut Canvas, bytes: &str) {
        let (mut x, mut y) = (0, 0);
        let mut ink = Rgb(255, 255, 255);
        let mut chars = bytes.chars().peekable();
        while let Some(ch) = chars.next() {
            if ch != '\x1b' {
                if ch == ' ' {
                    screen.cells[(y * screen.cols + x) as usize] = None;
                } else {
                    screen.put(x, y, ch, ink);
                }
                x += 1;
                continue;
            }
            assert_eq!(chars.next(), Some('['));
            let mut sequence = String::new();
            for ch in chars.by_ref() {
                sequence.push(ch);
                if ch.is_ascii_alphabetic() {
                    break;
                }
            }
            let numbers = |text: &str| {
                text.split(';')
                    .map(|n| n.parse::<i32>().unwrap())
                    .collect::<Vec<_>>()
            };
            if let Some(place) = sequence.strip_suffix('H') {
                let place = numbers(place);
                (y, x) = (place[0] - 1, place[1] - 1);
            } else if let Some(color) = sequence.strip_suffix('m') {
                let color = numbers(color);
                assert_eq!(&color[..2], [38, 2]);
                ink = Rgb(color[2] as u8, color[3] as u8, color[4] as u8);
            } else {
                assert!(
                    sequence == "?2026h" || sequence == "?2026l",
                    "unknown sequence {sequence}"
                );
            }
        }
    }

    fn scattered(rng: &mut Rng, cols: i32, rows: i32) -> Canvas {
        let mut canvas = Canvas::new(cols, rows);
        for _ in 0..(cols * rows / 2) {
            let color = Rgb(rng.below(3) as u8 * 100, 50, 200);
            canvas.put(
                rng.below(cols as usize) as i32,
                rng.below(rows as usize) as i32,
                ['a', '█', '·'][rng.below(3)],
                color,
            );
        }
        canvas
    }

    #[test]
    fn painting_turns_the_last_frame_into_the_next() {
        let mut rng = Rng::new(42);
        let mut screen = Canvas::new(17, 6);
        let mut last = Canvas::new(17, 6);
        for _ in 0..40 {
            let next = scattered(&mut rng, 17, 6);
            let mut bytes = String::new();
            paint(&last, &next, &mut bytes);
            show(&mut screen, &bytes);
            assert!(screen == next);
            last = next;
        }
    }

    #[test]
    fn a_frame_like_the_last_sends_nothing() {
        let mut rng = Rng::new(5);
        let frame = scattered(&mut rng, 20, 5);
        let mut bytes = String::from("kept");
        paint(&frame, &frame.clone(), &mut bytes);
        assert_eq!(bytes, "kept");
    }

    #[test]
    fn a_run_of_cells_in_one_color_moves_the_cursor_and_names_the_color_once() {
        let last = Canvas::new(10, 2);
        let mut next = Canvas::new(10, 2);
        for x in 2..6 {
            next.put(x, 1, '█', Rgb(1, 2, 3));
        }
        let mut bytes = String::new();
        paint(&last, &next, &mut bytes);
        assert_eq!(bytes, "\x1b[?2026h\x1b[2;3H\x1b[38;2;1;2;3m████\x1b[?2026l");
    }

    #[test]
    fn what_is_off_the_screen_is_not_drawn() {
        let mut canvas = Canvas::new(3, 2);
        canvas.put(-1, 0, 'x', Rgb(0, 0, 0));
        canvas.put(3, 1, 'x', Rgb(0, 0, 0));
        canvas.put(1, 2, 'x', Rgb(0, 0, 0));
        assert!(canvas.is_empty());
        canvas.put(2, 1, 'y', Rgb(0, 0, 0));
        assert_eq!(canvas.text(), "\n  y\n");
        assert!(Canvas::new(-4, 3).is_empty());
    }
}
