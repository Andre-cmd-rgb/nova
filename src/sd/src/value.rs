//! D-Bus values: what a message carries, built and read as a tree, so that a
//! caller never touches sd-bus's typed varargs.

use std::os::fd::{AsRawFd, OwnedFd};
use std::sync::Arc;

/// One D-Bus value, of any type.
///
/// An array keeps its element's signature, so that an empty one still says
/// what it would have held; a dictionary keeps its key's and value's.
#[derive(Debug, Clone)]
pub enum Value {
    Byte(u8),
    Bool(bool),
    Int16(i16),
    Uint16(u16),
    Int32(i32),
    Uint32(u32),
    Int64(i64),
    Uint64(u64),
    Double(f64),
    Str(String),
    Path(String),
    Signature(String),
    /// A file descriptor: one received is this process's own copy; one sent
    /// is copied by sd-bus, and stays the caller's.
    Fd(Arc<OwnedFd>),
    Array(String, Vec<Value>),
    Dict(String, String, Vec<(Value, Value)>),
    Struct(Vec<Value>),
    Variant(Box<Value>),
}

impl PartialEq for Value {
    fn eq(&self, other: &Value) -> bool {
        use Value::*;
        match (self, other) {
            (Byte(a), Byte(b)) => a == b,
            (Bool(a), Bool(b)) => a == b,
            (Int16(a), Int16(b)) => a == b,
            (Uint16(a), Uint16(b)) => a == b,
            (Int32(a), Int32(b)) => a == b,
            (Uint32(a), Uint32(b)) => a == b,
            (Int64(a), Int64(b)) => a == b,
            (Uint64(a), Uint64(b)) => a == b,
            (Double(a), Double(b)) => a == b,
            (Str(a), Str(b)) | (Path(a), Path(b)) | (Signature(a), Signature(b)) => a == b,
            (Fd(a), Fd(b)) => a.as_raw_fd() == b.as_raw_fd(),
            (Array(s, a), Array(t, b)) => s == t && a == b,
            (Dict(k, v, a), Dict(l, w, b)) => k == l && v == w && a == b,
            (Struct(a), Struct(b)) => a == b,
            (Variant(a), Variant(b)) => a == b,
            _ => false,
        }
    }
}

impl Value {
    /// A string.
    pub fn str(text: impl Into<String>) -> Value {
        Value::Str(text.into())
    }

    /// An object path.
    pub fn path(path: impl Into<String>) -> Value {
        Value::Path(path.into())
    }

    /// A variant holding <value>.
    pub fn variant(value: Value) -> Value {
        Value::Variant(Box::new(value))
    }

    /// An array of strings.
    pub fn strings<S: AsRef<str>>(items: &[S]) -> Value {
        Value::Array(
            "s".into(),
            items.iter().map(|s| Value::str(s.as_ref())).collect(),
        )
    }

    /// The commonest dictionary, a{sv}, from names and values (each put in a variant).
    pub fn options<S: AsRef<str>>(entries: Vec<(S, Value)>) -> Value {
        Value::Dict(
            "s".into(),
            "v".into(),
            entries
                .into_iter()
                .map(|(k, v)| (Value::str(k.as_ref()), Value::variant(v)))
                .collect(),
        )
    }

    /// The value's D-Bus signature.
    pub fn signature(&self) -> String {
        match self {
            Value::Byte(_) => "y".into(),
            Value::Bool(_) => "b".into(),
            Value::Int16(_) => "n".into(),
            Value::Uint16(_) => "q".into(),
            Value::Int32(_) => "i".into(),
            Value::Uint32(_) => "u".into(),
            Value::Int64(_) => "x".into(),
            Value::Uint64(_) => "t".into(),
            Value::Double(_) => "d".into(),
            Value::Str(_) => "s".into(),
            Value::Path(_) => "o".into(),
            Value::Signature(_) => "g".into(),
            Value::Fd(_) => "h".into(),
            Value::Array(element, _) => format!("a{element}"),
            Value::Dict(key, value, _) => format!("a{{{key}{value}}}"),
            Value::Struct(fields) => {
                let inner: String = fields.iter().map(Value::signature).collect();
                format!("({inner})")
            }
            Value::Variant(_) => "v".into(),
        }
    }

    /// The value inside a variant, however deep; any other value as it is.
    pub fn unvariant(&self) -> &Value {
        match self {
            Value::Variant(inner) => inner.unvariant(),
            other => other,
        }
    }

    /// A string, object path or signature's text.
    pub fn as_str(&self) -> Option<&str> {
        match self.unvariant() {
            Value::Str(s) | Value::Path(s) | Value::Signature(s) => Some(s),
            _ => None,
        }
    }

    pub fn as_bool(&self) -> Option<bool> {
        match self.unvariant() {
            Value::Bool(b) => Some(*b),
            _ => None,
        }
    }

    /// Any unsigned or non-negative integer, as a u64.
    pub fn as_u64(&self) -> Option<u64> {
        match *self.unvariant() {
            Value::Byte(n) => Some(n.into()),
            Value::Uint16(n) => Some(n.into()),
            Value::Uint32(n) => Some(n.into()),
            Value::Uint64(n) => Some(n),
            Value::Int16(n) => u64::try_from(n).ok(),
            Value::Int32(n) => u64::try_from(n).ok(),
            Value::Int64(n) => u64::try_from(n).ok(),
            _ => None,
        }
    }

    /// Any integer, as an i64 (a u64 too large for one is none).
    pub fn as_i64(&self) -> Option<i64> {
        match *self.unvariant() {
            Value::Byte(n) => Some(n.into()),
            Value::Uint16(n) => Some(n.into()),
            Value::Uint32(n) => Some(n.into()),
            Value::Uint64(n) => i64::try_from(n).ok(),
            Value::Int16(n) => Some(n.into()),
            Value::Int32(n) => Some(n.into()),
            Value::Int64(n) => Some(n),
            _ => None,
        }
    }

    pub fn as_f64(&self) -> Option<f64> {
        match *self.unvariant() {
            Value::Double(d) => Some(d),
            _ => self.as_i64().map(|n| n as f64),
        }
    }

    pub fn as_fd(&self) -> Option<&Arc<OwnedFd>> {
        match self.unvariant() {
            Value::Fd(fd) => Some(fd),
            _ => None,
        }
    }

    /// An array's elements, or a struct's fields.
    pub fn as_list(&self) -> Option<&[Value]> {
        match self.unvariant() {
            Value::Array(_, items) | Value::Struct(items) => Some(items),
            _ => None,
        }
    }

    /// A dictionary's entries.
    pub fn as_dict(&self) -> Option<&[(Value, Value)]> {
        match self.unvariant() {
            Value::Dict(_, _, entries) => Some(entries),
            _ => None,
        }
    }

    /// The value under a string key of a dictionary, out of its variant.
    pub fn get(&self, key: &str) -> Option<&Value> {
        self.as_dict()?
            .iter()
            .find(|(k, _)| k.as_str() == Some(key))
            .map(|(_, v)| v.unvariant())
    }

    /// An array of bytes as bytes: a{ay} paths and the like.
    pub fn as_bytes(&self) -> Option<Vec<u8>> {
        self.as_list()?
            .iter()
            .map(|b| match b {
                Value::Byte(b) => Some(*b),
                _ => None,
            })
            .collect()
    }
}

/// A signature cut into its complete types: "a{sv}su" is "a{sv}", "s", "u".
/// None for one that is not well formed.
pub fn split_signature(signature: &str) -> Option<Vec<&str>> {
    let mut types = Vec::new();
    let mut rest = signature;
    while !rest.is_empty() {
        let length = complete_type(rest.as_bytes())?;
        types.push(&rest[..length]);
        rest = &rest[length..];
    }
    Some(types)
}

/// How long the complete type at the start of <signature> is.
fn complete_type(signature: &[u8]) -> Option<usize> {
    match *signature.first()? {
        b'y' | b'b' | b'n' | b'q' | b'i' | b'u' | b'x' | b't' | b'd' | b's' | b'o' | b'g'
        | b'h' | b'v' => Some(1),
        b'a' => Some(1 + complete_type(&signature[1..])?),
        open @ (b'(' | b'{') => {
            let close = if open == b'(' { b')' } else { b'}' };
            let mut at = 1;
            let mut fields = 0;
            while *signature.get(at)? != close {
                at += complete_type(&signature[at..])?;
                fields += 1;
            }
            // A struct holds something; a dictionary entry a basic key and one value.
            let fine = if open == b'(' {
                fields > 0
            } else {
                fields == 2 && b"ybnqiuxtdsogh".contains(&signature[1])
            };
            fine.then_some(at + 1)
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn signatures_of_values() {
        assert_eq!(Value::strings(&["a"]).signature(), "as");
        assert_eq!(
            Value::options(vec![("k", Value::Bool(true))]).signature(),
            "a{sv}"
        );
        assert_eq!(
            Value::Struct(vec![Value::Uint32(1), Value::str("x")]).signature(),
            "(us)"
        );
        assert_eq!(Value::Array("(us)".into(), vec![]).signature(), "a(us)");
    }

    #[test]
    fn a_signature_is_cut_into_complete_types() {
        assert_eq!(split_signature("a{sv}su").unwrap(), vec!["a{sv}", "s", "u"]);
        assert_eq!(
            split_signature("a(oa{sv})h").unwrap(),
            vec!["a(oa{sv})", "h"]
        );
        assert_eq!(split_signature("").unwrap(), Vec::<&str>::new());
        assert!(split_signature("a").is_none());
        assert!(split_signature("{sv}").unwrap().len() == 1);
        assert!(split_signature("a{vs}").is_none());
        assert!(split_signature("()").is_none());
        assert!(split_signature("(s").is_none());
    }

    #[test]
    fn values_are_read_through_variants() {
        let options = Value::options(vec![("Name", Value::str("x")), ("Size", Value::Uint64(4))]);
        assert_eq!(options.get("Name").and_then(Value::as_str), Some("x"));
        assert_eq!(options.get("Size").and_then(Value::as_u64), Some(4));
        assert!(options.get("Other").is_none());
        assert_eq!(
            Value::variant(Value::variant(Value::Bool(true))).as_bool(),
            Some(true)
        );
        assert_eq!(Value::Int32(-1).as_u64(), None);
    }
}
