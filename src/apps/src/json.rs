//! A JSON writer for the catalog: objects written a field at a time.

pub fn string(out: &mut String, s: &str) {
    out.push('"');
    for ch in s.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
}

/// An object, its fields added in order.
pub struct Object<'a> {
    out: &'a mut String,
    first: bool,
}

impl<'a> Object<'a> {
    pub fn new(out: &'a mut String) -> Self {
        out.push('{');
        Object { out, first: true }
    }

    fn key(&mut self, key: &str) {
        if !self.first {
            self.out.push(',');
        }
        self.first = false;
        string(self.out, key);
        self.out.push(':');
    }

    pub fn str(&mut self, key: &str, value: &str) -> &mut Self {
        self.key(key);
        string(self.out, value);
        self
    }

    /// A string field, left out when it is empty.
    pub fn some(&mut self, key: &str, value: &str) -> &mut Self {
        if !value.is_empty() {
            self.str(key, value);
        }
        self
    }

    pub fn num(&mut self, key: &str, value: u64) -> &mut Self {
        self.key(key);
        self.out.push_str(&value.to_string());
        self
    }

    pub fn bool(&mut self, key: &str, value: bool) -> &mut Self {
        self.key(key);
        self.out.push_str(if value { "true" } else { "false" });
        self
    }

    pub fn strs(&mut self, key: &str, values: &[String]) -> &mut Self {
        self.key(key);
        self.out.push('[');
        for (i, v) in values.iter().enumerate() {
            if i > 0 {
                self.out.push(',');
            }
            string(self.out, v);
        }
        self.out.push(']');
        self
    }

    /// A field whose value the closure writes, raw.
    pub fn raw(&mut self, key: &str, write: impl FnOnce(&mut String)) -> &mut Self {
        self.key(key);
        write(self.out);
        self
    }

    pub fn end(&mut self) {
        self.out.push('}');
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn escapes_and_orders_fields() {
        let mut out = String::new();
        Object::new(&mut out)
            .str("a", "say \"hi\"\n\u{1}")
            .some("empty", "")
            .num("n", 42)
            .bool("b", true)
            .strs("l", &["x".into(), "\\".into()])
            .raw("o", |o| o.push_str("{}"))
            .end();
        assert_eq!(
            out,
            r#"{"a":"say \"hi\"\n\u0001","n":42,"b":true,"l":["x","\\"],"o":{}}"#
        );
    }
}
