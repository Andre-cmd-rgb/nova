//! JSON, as far as the tests need it: the service's state file and the
//! buttons a notification carries are read, and an advertisement or a
//! notification is written for the transcript the way the tests have always
//! printed them (keys in order, ", " and ": " between). No crate: Nova's Rust
//! has none.

use std::collections::BTreeMap;
use std::fmt;

#[derive(Debug, Clone, PartialEq)]
pub enum Json {
    Null,
    Bool(bool),
    Num(f64),
    Str(String),
    Arr(Vec<Json>),
    Obj(BTreeMap<String, Json>),
}

impl Json {
    pub fn str(text: &str) -> Json {
        Json::Str(text.into())
    }

    pub fn num(n: impl Into<f64>) -> Json {
        Json::Num(n.into())
    }

    pub fn strings(items: &[&str]) -> Json {
        Json::Arr(items.iter().map(|s| Json::str(s)).collect())
    }

    pub fn obj(entries: Vec<(&str, Json)>) -> Json {
        Json::Obj(entries.into_iter().map(|(k, v)| (k.into(), v)).collect())
    }

    pub fn get(&self, key: &str) -> Option<&Json> {
        match self {
            Json::Obj(entries) => entries.get(key),
            _ => None,
        }
    }

    pub fn as_str(&self) -> Option<&str> {
        match self {
            Json::Str(s) => Some(s),
            _ => None,
        }
    }

    pub fn as_f64(&self) -> Option<f64> {
        match self {
            Json::Num(n) => Some(*n),
            _ => None,
        }
    }

    pub fn as_bool(&self) -> Option<bool> {
        match self {
            Json::Bool(b) => Some(*b),
            _ => None,
        }
    }

    pub fn as_list(&self) -> &[Json] {
        match self {
            Json::Arr(items) => items,
            _ => &[],
        }
    }

    /// What <text> says, or none for text that is not JSON.
    pub fn parse(text: &str) -> Option<Json> {
        let mut parser = Parser {
            text: text.as_bytes(),
            at: 0,
        };
        let value = parser.value()?;
        parser.space();
        (parser.at == parser.text.len()).then_some(value)
    }
}

impl fmt::Display for Json {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            Json::Null => write!(f, "null"),
            Json::Bool(b) => write!(f, "{b}"),
            Json::Num(n) if n.fract() == 0.0 && n.abs() < 1e15 => write!(f, "{}", *n as i64),
            Json::Num(n) => write!(f, "{n}"),
            Json::Str(s) => {
                write!(f, "\"")?;
                for c in s.chars() {
                    match c {
                        '"' => write!(f, "\\\"")?,
                        '\\' => write!(f, "\\\\")?,
                        '\n' => write!(f, "\\n")?,
                        c if (c as u32) < 0x20 => write!(f, "\\u{:04x}", c as u32)?,
                        c => write!(f, "{c}")?,
                    }
                }
                write!(f, "\"")
            }
            Json::Arr(items) => {
                write!(f, "[")?;
                for (i, item) in items.iter().enumerate() {
                    if i > 0 {
                        write!(f, ", ")?;
                    }
                    write!(f, "{item}")?;
                }
                write!(f, "]")
            }
            Json::Obj(entries) => {
                write!(f, "{{")?;
                for (i, (key, value)) in entries.iter().enumerate() {
                    if i > 0 {
                        write!(f, ", ")?;
                    }
                    write!(f, "{}: {value}", Json::str(key))?;
                }
                write!(f, "}}")
            }
        }
    }
}

struct Parser<'a> {
    text: &'a [u8],
    at: usize,
}

impl Parser<'_> {
    fn space(&mut self) {
        while self.text.get(self.at).is_some_and(u8::is_ascii_whitespace) {
            self.at += 1;
        }
    }

    fn eat(&mut self, byte: u8) -> Option<()> {
        self.space();
        (self.text.get(self.at) == Some(&byte)).then(|| self.at += 1)
    }

    fn word(&mut self, word: &str, value: Json) -> Option<Json> {
        self.text[self.at..].starts_with(word.as_bytes()).then(|| {
            self.at += word.len();
            value
        })
    }

    fn value(&mut self) -> Option<Json> {
        self.space();
        match *self.text.get(self.at)? {
            b'{' => {
                self.at += 1;
                let mut entries = BTreeMap::new();
                if self.eat(b'}').is_some() {
                    return Some(Json::Obj(entries));
                }
                loop {
                    self.space();
                    let key = self.string()?;
                    self.eat(b':')?;
                    entries.insert(key, self.value()?);
                    if self.eat(b',').is_none() {
                        self.eat(b'}')?;
                        return Some(Json::Obj(entries));
                    }
                }
            }
            b'[' => {
                self.at += 1;
                let mut items = Vec::new();
                if self.eat(b']').is_some() {
                    return Some(Json::Arr(items));
                }
                loop {
                    items.push(self.value()?);
                    if self.eat(b',').is_none() {
                        self.eat(b']')?;
                        return Some(Json::Arr(items));
                    }
                }
            }
            b'"' => self.string().map(Json::Str),
            b't' => self.word("true", Json::Bool(true)),
            b'f' => self.word("false", Json::Bool(false)),
            b'n' => self.word("null", Json::Null),
            _ => {
                let start = self.at;
                while self
                    .text
                    .get(self.at)
                    .is_some_and(|b| b"+-.eE0123456789".contains(b))
                {
                    self.at += 1;
                }
                std::str::from_utf8(&self.text[start..self.at])
                    .ok()?
                    .parse()
                    .ok()
                    .map(Json::Num)
            }
        }
    }

    fn hex4(&mut self) -> Option<u32> {
        let digits = self.text.get(self.at..self.at + 4)?;
        self.at += 4;
        u32::from_str_radix(std::str::from_utf8(digits).ok()?, 16).ok()
    }

    fn string(&mut self) -> Option<String> {
        if self.text.get(self.at) != Some(&b'"') {
            return None;
        }
        self.at += 1;
        let mut bytes = Vec::new();
        loop {
            let byte = *self.text.get(self.at)?;
            self.at += 1;
            match byte {
                b'"' => return String::from_utf8(bytes).ok(),
                b'\\' => {
                    let escape = *self.text.get(self.at)?;
                    self.at += 1;
                    let c = match escape {
                        b'n' => '\n',
                        b't' => '\t',
                        b'r' => '\r',
                        b'b' => '\u{8}',
                        b'f' => '\u{c}',
                        b'u' => {
                            let mut code = self.hex4()?;
                            // A character outside the first plane comes as a pair.
                            if (0xD800..0xDC00).contains(&code)
                                && self.text[self.at..].starts_with(b"\\u")
                            {
                                self.at += 2;
                                let low = self.hex4()?;
                                code = 0x10000
                                    + ((code - 0xD800) << 10)
                                    + (low.wrapping_sub(0xDC00) & 0x3FF);
                            }
                            char::from_u32(code)?
                        }
                        other => other as char,
                    };
                    let mut buffer = [0; 4];
                    bytes.extend_from_slice(c.encode_utf8(&mut buffer).as_bytes());
                }
                other => bytes.push(other),
            }
        }
    }
}
