//! The text to play, as the characters in it and where each one goes.

/// One character of the text, at its column and row within the text.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Glyph {
    pub x: i32,
    pub y: i32,
    pub ch: char,
}

/// A text as its visible characters: spaces are not part of it. Its box is the
/// smallest that holds them all, so blank lines and indentation around a text
/// do not put it off centre.
pub struct Text {
    pub glyphs: Vec<Glyph>,
    pub width: i32,
    pub height: i32,
}

impl Text {
    pub fn parse(source: &str) -> Text {
        let mut glyphs = Vec::new();
        for (row, line) in source.lines().enumerate() {
            let mut column = 0;
            for ch in line.chars() {
                match ch {
                    // A tab goes to the next of the columns eight apart.
                    '\t' => column = (column / 8 + 1) * 8,
                    _ if ch.is_control() => {}
                    _ if ch.is_whitespace() => column += 1,
                    _ => {
                        glyphs.push(Glyph {
                            x: column,
                            y: row as i32,
                            ch,
                        });
                        column += 1;
                    }
                }
            }
        }
        let left = glyphs.iter().map(|g| g.x).min().unwrap_or(0);
        let top = glyphs.iter().map(|g| g.y).min().unwrap_or(0);
        for glyph in &mut glyphs {
            glyph.x -= left;
            glyph.y -= top;
        }
        let width = glyphs.iter().map(|g| g.x + 1).max().unwrap_or(0);
        let height = glyphs.iter().map(|g| g.y + 1).max().unwrap_or(0);
        Text {
            glyphs,
            width,
            height,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_text_is_its_visible_characters_in_the_smallest_box() {
        let text = Text::parse("\n\n    ab\n   c  d  \n\n");
        assert_eq!((text.width, text.height), (4, 2));
        let at = |x, y| {
            text.glyphs
                .iter()
                .find(|g| (g.x, g.y) == (x, y))
                .map(|g| g.ch)
        };
        assert_eq!(at(1, 0), Some('a'));
        assert_eq!(at(2, 0), Some('b'));
        assert_eq!(at(0, 1), Some('c'));
        assert_eq!(at(3, 1), Some('d'));
        assert_eq!(text.glyphs.len(), 4);
    }

    #[test]
    fn tabs_carriage_returns_and_nothing_at_all() {
        let text = Text::parse("a\tb\r\nc\r\n");
        assert_eq!((text.width, text.height), (9, 2));
        assert_eq!(text.glyphs.len(), 3);
        let empty = Text::parse("  \n\n");
        assert!(empty.glyphs.is_empty());
        assert_eq!((empty.width, empty.height), (0, 0));
    }

    #[test]
    fn the_wordmark_keeps_its_star_above_the_last_letter() {
        let text = Text::parse(include_str!("../../../theme/wordmark/nova.txt"));
        assert_eq!((text.width, text.height), (49, 11));
        let top: Vec<_> = text.glyphs.iter().filter(|g| g.y == 0).collect();
        assert_eq!(top.len(), 1);
        assert!(top[0].x > text.width / 2);
    }
}
