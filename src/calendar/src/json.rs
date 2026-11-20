//! JSON as the Calendar's files keep it: objects in the order their keys
//! came, written as the sync always wrote them (two spaces of indent for the
//! calendar list, one line for the rest, every character past ASCII as a
//! \u escape), so a file reads the same after this sync as before it.

#[derive(Debug, Clone, PartialEq)]
pub enum Json {
    Null,
    Bool(bool),
    Int(i64),
    Float(f64),
    Str(String),
    Array(Vec<Json>),
    Object(Vec<(String, Json)>),
}

impl Json {
    pub fn object() -> Json {
        Json::Object(Vec::new())
    }

    pub fn str(text: impl Into<String>) -> Json {
        Json::Str(text.into())
    }

    /// <value>, or null for none.
    pub fn opt(value: Option<impl Into<String>>) -> Json {
        value.map(|v| Json::Str(v.into())).unwrap_or(Json::Null)
    }

    pub fn get(&self, key: &str) -> Option<&Json> {
        match self {
            Json::Object(fields) => fields.iter().find(|(k, _)| k == key).map(|(_, v)| v),
            _ => None,
        }
    }

    pub fn get_mut(&mut self, key: &str) -> Option<&mut Json> {
        match self {
            Json::Object(fields) => fields.iter_mut().find(|(k, _)| k == key).map(|(_, v)| v),
            _ => None,
        }
    }

    /// The key set to <value>: in its place if it is there, else last.
    pub fn set(&mut self, key: &str, value: Json) {
        if let Json::Object(fields) = self {
            match fields.iter_mut().find(|(k, _)| k == key) {
                Some((_, v)) => *v = value,
                None => fields.push((key.to_string(), value)),
            }
        }
    }

    pub fn remove(&mut self, key: &str) -> Option<Json> {
        match self {
            Json::Object(fields) => {
                let at = fields.iter().position(|(k, _)| k == key)?;
                Some(fields.remove(at).1)
            }
            _ => None,
        }
    }

    pub fn as_str(&self) -> Option<&str> {
        match self {
            Json::Str(s) => Some(s),
            _ => None,
        }
    }

    /// The string at <key>, or "" (the sync's `.get(key, "")`).
    pub fn text(&self, key: &str) -> &str {
        self.get(key).and_then(Json::as_str).unwrap_or("")
    }

    pub fn as_f64(&self) -> Option<f64> {
        match self {
            Json::Int(n) => Some(*n as f64),
            Json::Float(n) => Some(*n),
            _ => None,
        }
    }

    pub fn as_array(&self) -> Option<&Vec<Json>> {
        match self {
            Json::Array(items) => Some(items),
            _ => None,
        }
    }

    pub fn as_array_mut(&mut self) -> Option<&mut Vec<Json>> {
        match self {
            Json::Array(items) => Some(items),
            _ => None,
        }
    }

    pub fn is_object(&self) -> bool {
        matches!(self, Json::Object(_))
    }

    /// Python's truth of a value: null, false, zero and empty ones are false.
    pub fn truthy(&self) -> bool {
        match self {
            Json::Null => false,
            Json::Bool(b) => *b,
            Json::Int(n) => *n != 0,
            Json::Float(n) => *n != 0.0,
            Json::Str(s) => !s.is_empty(),
            Json::Array(a) => !a.is_empty(),
            Json::Object(o) => !o.is_empty(),
        }
    }

    /// Whether <key> holds a true value.
    pub fn is(&self, key: &str) -> bool {
        self.get(key).is_some_and(Json::truthy)
    }
}

// ---- reading

/// The document in <text>; none for one that is not JSON.
pub fn parse(text: &str) -> Option<Json> {
    let mut r = Reader {
        b: text.as_bytes(),
        at: 0,
    };
    r.space();
    let value = r.value(0)?;
    r.space();
    (r.at == r.b.len()).then_some(value)
}

struct Reader<'a> {
    b: &'a [u8],
    at: usize,
}

impl Reader<'_> {
    fn space(&mut self) {
        while self.at < self.b.len() && matches!(self.b[self.at], b' ' | b'\t' | b'\n' | b'\r') {
            self.at += 1;
        }
    }

    fn eat(&mut self, word: &[u8]) -> bool {
        if self.b[self.at..].starts_with(word) {
            self.at += word.len();
            true
        } else {
            false
        }
    }

    fn value(&mut self, depth: usize) -> Option<Json> {
        if depth > 200 {
            return None;
        }
        match *self.b.get(self.at)? {
            b'{' => {
                self.at += 1;
                let mut fields: Vec<(String, Json)> = Vec::new();
                self.space();
                if self.eat(b"}") {
                    return Some(Json::Object(fields));
                }
                loop {
                    self.space();
                    if self.b.get(self.at) != Some(&b'"') {
                        return None;
                    }
                    let key = self.string()?;
                    self.space();
                    if !self.eat(b":") {
                        return None;
                    }
                    self.space();
                    let value = self.value(depth + 1)?;
                    // A key twice: the last value, in the first one's place.
                    match fields.iter_mut().find(|(k, _)| *k == key) {
                        Some((_, v)) => *v = value,
                        None => fields.push((key, value)),
                    }
                    self.space();
                    if self.eat(b",") {
                        continue;
                    }
                    if self.eat(b"}") {
                        return Some(Json::Object(fields));
                    }
                    return None;
                }
            }
            b'[' => {
                self.at += 1;
                let mut items = Vec::new();
                self.space();
                if self.eat(b"]") {
                    return Some(Json::Array(items));
                }
                loop {
                    self.space();
                    items.push(self.value(depth + 1)?);
                    self.space();
                    if self.eat(b",") {
                        continue;
                    }
                    if self.eat(b"]") {
                        return Some(Json::Array(items));
                    }
                    return None;
                }
            }
            b'"' => self.string().map(Json::Str),
            b't' => self.eat(b"true").then_some(Json::Bool(true)),
            b'f' => self.eat(b"false").then_some(Json::Bool(false)),
            b'n' => self.eat(b"null").then_some(Json::Null),
            _ => self.number(),
        }
    }

    fn number(&mut self) -> Option<Json> {
        let start = self.at;
        let mut float = false;
        if self.b.get(self.at) == Some(&b'-') {
            self.at += 1;
        }
        let digits = |r: &mut Self| {
            let s = r.at;
            while r.at < r.b.len() && r.b[r.at].is_ascii_digit() {
                r.at += 1;
            }
            r.at > s
        };
        if !digits(self) {
            return None;
        }
        if self.b.get(self.at) == Some(&b'.') {
            self.at += 1;
            float = true;
            if !digits(self) {
                return None;
            }
        }
        if matches!(self.b.get(self.at), Some(b'e' | b'E')) {
            self.at += 1;
            float = true;
            if matches!(self.b.get(self.at), Some(b'+' | b'-')) {
                self.at += 1;
            }
            if !digits(self) {
                return None;
            }
        }
        let text = std::str::from_utf8(&self.b[start..self.at]).ok()?;
        if !float {
            if let Ok(n) = text.parse::<i64>() {
                return Some(Json::Int(n));
            }
        }
        text.parse::<f64>().ok().map(Json::Float)
    }

    fn hex4(&mut self) -> Option<u32> {
        let h = self.b.get(self.at..self.at + 4)?;
        let n = u32::from_str_radix(std::str::from_utf8(h).ok()?, 16).ok()?;
        self.at += 4;
        Some(n)
    }

    fn string(&mut self) -> Option<String> {
        self.at += 1;
        let mut out = Vec::new();
        loop {
            let c = *self.b.get(self.at)?;
            self.at += 1;
            match c {
                b'"' => return String::from_utf8(out).ok(),
                b'\\' => {
                    let e = *self.b.get(self.at)?;
                    self.at += 1;
                    let ch = match e {
                        b'"' => '"',
                        b'\\' => '\\',
                        b'/' => '/',
                        b'b' => '\u{8}',
                        b'f' => '\u{c}',
                        b'n' => '\n',
                        b'r' => '\r',
                        b't' => '\t',
                        b'u' => {
                            let hi = self.hex4()?;
                            if (0xD800..0xDC00).contains(&hi)
                                && self.b[self.at..].starts_with(b"\\u")
                            {
                                let save = self.at;
                                self.at += 2;
                                let lo = self.hex4()?;
                                if (0xDC00..0xE000).contains(&lo) {
                                    char::from_u32(0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00))?
                                } else {
                                    self.at = save;
                                    '\u{FFFD}'
                                }
                            } else {
                                char::from_u32(hi).unwrap_or('\u{FFFD}')
                            }
                        }
                        _ => return None,
                    };
                    let mut buf = [0; 4];
                    out.extend_from_slice(ch.encode_utf8(&mut buf).as_bytes());
                }
                c if c < 0x20 => return None,
                c => out.push(c),
            }
        }
    }
}

// ---- writing

/// <value> on one line, as `json.dumps` writes it.
pub fn dumps(value: &Json) -> String {
    let mut out = String::new();
    write(&mut out, value, None, 0);
    out
}

/// <value> with two spaces of indent, as `json.dumps(indent=2)` writes it.
pub fn dumps_indented(value: &Json) -> String {
    let mut out = String::new();
    write(&mut out, value, Some(2), 0);
    out
}

fn newline(out: &mut String, indent: Option<usize>, level: usize) {
    if let Some(n) = indent {
        out.push('\n');
        out.extend(std::iter::repeat_n(' ', n * level));
    }
}

fn write(out: &mut String, value: &Json, indent: Option<usize>, level: usize) {
    let comma = if indent.is_some() { "," } else { ", " };
    match value {
        Json::Null => out.push_str("null"),
        Json::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        Json::Int(n) => out.push_str(&n.to_string()),
        Json::Float(f) => out.push_str(&float(*f)),
        Json::Str(s) => quote_into(out, s),
        Json::Array(items) => {
            if items.is_empty() {
                out.push_str("[]");
                return;
            }
            out.push('[');
            for (i, item) in items.iter().enumerate() {
                if i > 0 {
                    out.push_str(comma);
                }
                newline(out, indent, level + 1);
                write(out, item, indent, level + 1);
            }
            newline(out, indent, level);
            out.push(']');
        }
        Json::Object(fields) => {
            if fields.is_empty() {
                out.push_str("{}");
                return;
            }
            out.push('{');
            for (i, (k, v)) in fields.iter().enumerate() {
                if i > 0 {
                    out.push_str(comma);
                }
                newline(out, indent, level + 1);
                quote_into(out, k);
                out.push_str(": ");
                write(out, v, indent, level + 1);
            }
            newline(out, indent, level);
            out.push('}');
        }
    }
}

/// A string quoted, ASCII only: what is past it as \u escapes, in pairs of
/// surrogates above the first plane.
pub fn quote_into(out: &mut String, s: &str) {
    out.push('"');
    for ch in s.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{8}' => out.push_str("\\b"),
            '\u{c}' => out.push_str("\\f"),
            c if (c as u32) < 0x20 || (c as u32) > 0x7e => {
                let mut units = [0u16; 2];
                for u in c.encode_utf16(&mut units) {
                    out.push_str(&format!("\\u{u:04x}"));
                }
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

/// A float as Python's repr writes it: the shortest digits that read back
/// the same, fixed between 1e-4 and 1e16 (with ".0" when whole), else with
/// an exponent.
fn float(f: f64) -> String {
    if f.is_nan() {
        return "NaN".into();
    }
    if f.is_infinite() {
        return if f > 0.0 { "Infinity" } else { "-Infinity" }.into();
    }
    if f == 0.0 {
        return if f.is_sign_negative() { "-0.0" } else { "0.0" }.into();
    }
    let sci = format!("{f:e}");
    let (mantissa, exp) = sci.split_once('e').expect("{:e} has an exponent");
    let exp: i32 = exp.parse().expect("an exponent");
    let (sign, mantissa) = match mantissa.strip_prefix('-') {
        Some(m) => ("-", m),
        None => ("", mantissa),
    };
    let digits: String = mantissa.chars().filter(|c| *c != '.').collect();
    if (-4..16).contains(&exp) {
        let point = exp + 1;
        let body = if point <= 0 {
            format!("0.{}{}", "0".repeat((-point) as usize), digits)
        } else if point as usize >= digits.len() {
            format!("{}{}.0", digits, "0".repeat(point as usize - digits.len()))
        } else {
            format!(
                "{}.{}",
                &digits[..point as usize],
                &digits[point as usize..]
            )
        };
        format!("{sign}{body}")
    } else {
        let m = if digits.len() > 1 {
            format!("{}.{}", &digits[..1], &digits[1..])
        } else {
            digits
        };
        format!(
            "{sign}{m}e{}{:02}",
            if exp < 0 { '-' } else { '+' },
            exp.abs()
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_and_writes_as_python_does() {
        let text = r#"{"version": 1, "b": [true, null, 2.5, "xé😀"], "a": {}, "e": []}"#;
        let v = parse(text).unwrap();
        assert_eq!(
            v.get("b").unwrap().as_array().unwrap()[3].as_str(),
            Some("xé😀")
        );
        assert_eq!(dumps(&v), text.replace("xé😀", "x\\u00e9\\ud83d\\ude00"));
        assert_eq!(
            dumps_indented(&v),
            "{\n  \"version\": 1,\n  \"b\": [\n    true,\n    null,\n    2.5,\n    \"x\\u00e9\\ud83d\\ude00\"\n  ],\n  \"a\": {},\n  \"e\": []\n}"
        );
        assert!(parse("{\"a\": 1,}").is_none());
        assert!(parse("[1] 2").is_none());
        assert_eq!(
            parse(r#"{"a": 1, "a": 2}"#).unwrap(),
            Json::Object(vec![("a".into(), Json::Int(2))])
        );
    }

    #[test]
    fn floats_as_repr() {
        for (f, text) in [
            (0.0, "0.0"),
            (3.0, "3.0"),
            (1795123987.654321, "1795123987.654321"),
            (0.1, "0.1"),
            (1e16, "1e+16"),
            (1.5e-5, "1.5e-05"),
            (0.0001, "0.0001"),
            (-2.25, "-2.25"),
            (123456789012345.0, "123456789012345.0"),
        ] {
            assert_eq!(float(f), text, "{f}");
        }
    }
}
