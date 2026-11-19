//! Just enough JSON to read what Hyprland answers (`j/clients`).

use std::collections::BTreeMap;

#[derive(Debug, Clone, PartialEq)]
pub enum Json {
    Null,
    Bool(bool),
    Number(f64),
    Str(String),
    Array(Vec<Json>),
    Object(BTreeMap<String, Json>),
}

impl Json {
    pub fn get(&self, key: &str) -> Option<&Json> {
        match self {
            Json::Object(fields) => fields.get(key),
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
            Json::Number(n) => Some(*n),
            _ => None,
        }
    }

    pub fn as_array(&self) -> Option<&[Json]> {
        match self {
            Json::Array(items) => Some(items),
            _ => None,
        }
    }
}

/// The document in <text>; none for one that is not JSON.
pub fn parse(text: &str) -> Option<Json> {
    let mut reader = Reader {
        bytes: text.as_bytes(),
        at: 0,
    };
    let value = reader.value(0)?;
    reader.space();
    (reader.at == reader.bytes.len()).then_some(value)
}

struct Reader<'a> {
    bytes: &'a [u8],
    at: usize,
}

impl Reader<'_> {
    fn space(&mut self) {
        while matches!(self.bytes.get(self.at), Some(b' ' | b'\t' | b'\n' | b'\r')) {
            self.at += 1;
        }
    }

    fn eat(&mut self, byte: u8) -> bool {
        self.space();
        if self.bytes.get(self.at) == Some(&byte) {
            self.at += 1;
            true
        } else {
            false
        }
    }

    fn word(&mut self, word: &str, value: Json) -> Option<Json> {
        self.bytes[self.at..].starts_with(word.as_bytes()).then(|| {
            self.at += word.len();
            value
        })
    }

    fn value(&mut self, depth: usize) -> Option<Json> {
        // Deep enough for any answer of Hyprland's, and no deeper.
        if depth > 64 {
            return None;
        }
        self.space();
        match *self.bytes.get(self.at)? {
            b'{' => {
                self.at += 1;
                let mut fields = BTreeMap::new();
                if self.eat(b'}') {
                    return Some(Json::Object(fields));
                }
                loop {
                    self.space();
                    let key = self.string()?;
                    if !self.eat(b':') {
                        return None;
                    }
                    let value = self.value(depth + 1)?;
                    fields.insert(key, value);
                    if self.eat(b'}') {
                        return Some(Json::Object(fields));
                    }
                    if !self.eat(b',') {
                        return None;
                    }
                }
            }
            b'[' => {
                self.at += 1;
                let mut items = Vec::new();
                if self.eat(b']') {
                    return Some(Json::Array(items));
                }
                loop {
                    items.push(self.value(depth + 1)?);
                    if self.eat(b']') {
                        return Some(Json::Array(items));
                    }
                    if !self.eat(b',') {
                        return None;
                    }
                }
            }
            b'"' => self.string().map(Json::Str),
            b't' => self.word("true", Json::Bool(true)),
            b'f' => self.word("false", Json::Bool(false)),
            b'n' => self.word("null", Json::Null),
            _ => {
                let start = self.at;
                while matches!(
                    self.bytes.get(self.at),
                    Some(b'-' | b'+' | b'.' | b'e' | b'E' | b'0'..=b'9')
                ) {
                    self.at += 1;
                }
                std::str::from_utf8(&self.bytes[start..self.at])
                    .ok()?
                    .parse()
                    .ok()
                    .map(Json::Number)
            }
        }
    }

    fn string(&mut self) -> Option<String> {
        if self.bytes.get(self.at) != Some(&b'"') {
            return None;
        }
        self.at += 1;
        let mut out = Vec::new();
        loop {
            match *self.bytes.get(self.at)? {
                b'"' => {
                    self.at += 1;
                    return String::from_utf8(out).ok();
                }
                b'\\' => {
                    self.at += 1;
                    let escaped = *self.bytes.get(self.at)?;
                    self.at += 1;
                    let ch = match escaped {
                        b'"' => '"',
                        b'\\' => '\\',
                        b'/' => '/',
                        b'b' => '\u{8}',
                        b'f' => '\u{c}',
                        b'n' => '\n',
                        b'r' => '\r',
                        b't' => '\t',
                        b'u' => {
                            let mut code = self.hex4()?;
                            // A pair of surrogates is one character.
                            if (0xD800..0xDC00).contains(&code)
                                && self.bytes[self.at..].starts_with(b"\\u")
                            {
                                self.at += 2;
                                let low = self.hex4()?;
                                code = 0x10000
                                    + ((code - 0xD800) << 10)
                                    + (low.wrapping_sub(0xDC00) & 0x3FF);
                            }
                            char::from_u32(code).unwrap_or('\u{FFFD}')
                        }
                        _ => return None,
                    };
                    let mut buffer = [0; 4];
                    out.extend_from_slice(ch.encode_utf8(&mut buffer).as_bytes());
                }
                byte => {
                    out.push(byte);
                    self.at += 1;
                }
            }
        }
    }

    fn hex4(&mut self) -> Option<u32> {
        let digits = std::str::from_utf8(self.bytes.get(self.at..self.at + 4)?).ok()?;
        self.at += 4;
        u32::from_str_radix(digits, 16).ok()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hyprlands_clients_are_read() {
        let doc = parse(
            r#"[{"address": "0x55d0", "pid": 4242, "class": "foot", "initialClass": "",
                "title": "a \"quoted\" tab\nline é 😀", "floating": false, "grouped": [], "x": null}]"#,
        )
        .unwrap();
        let first = &doc.as_array().unwrap()[0];
        assert_eq!(first.get("address").and_then(Json::as_str), Some("0x55d0"));
        assert_eq!(first.get("pid").and_then(Json::as_f64), Some(4242.0));
        assert_eq!(
            first.get("title").and_then(Json::as_str),
            Some("a \"quoted\" tab\nline é 😀")
        );
        assert_eq!(first.get("floating"), Some(&Json::Bool(false)));
        assert_eq!(first.get("x"), Some(&Json::Null));
    }

    #[test]
    fn what_is_not_json_is_none() {
        assert!(parse("").is_none());
        assert!(parse("[1,").is_none());
        assert!(parse("{\"a\" 1}").is_none());
        assert!(parse("[1] x").is_none());
        assert!(parse("ok").is_none());
        assert_eq!(parse(" [ ] "), Some(Json::Array(vec![])));
    }
}
