//! What the service reads of BlueZ's objects and writes in its calls: D-Bus
//! values as nova-sd hands them over, and the few ways of reading them the
//! service needs beyond nova-sd's own.

use std::collections::BTreeMap;

pub use nova_sd::Value;

/// A byte array.
pub fn bytes(bytes: &[u8]) -> Value {
    Value::Array("y".into(), bytes.iter().map(|&b| Value::Byte(b)).collect())
}

/// As a condition, the way BlueZ's properties are read: false, zero, empty
/// and nothing are false.
pub fn truthy(value: &Value) -> bool {
    match value.unvariant() {
        Value::Bool(b) => *b,
        Value::Double(n) => *n != 0.0,
        Value::Str(s) | Value::Path(s) | Value::Signature(s) => !s.is_empty(),
        Value::Array(_, items) | Value::Struct(items) => !items.is_empty(),
        Value::Dict(_, _, items) => !items.is_empty(),
        other => other.as_i64().is_none_or(|n| n != 0),
    }
}

/// An array of strings, those of its items that are.
pub fn strings_of(value: &Value) -> Vec<String> {
    value
        .as_list()
        .unwrap_or_default()
        .iter()
        .filter_map(|v| v.as_str().map(str::to_string))
        .collect()
}

/// A dictionary as name → value, its values out of their variants.
pub fn map_of(value: &Value) -> BTreeMap<String, Value> {
    value
        .as_dict()
        .unwrap_or_default()
        .iter()
        .filter_map(|(k, v)| Some((k.as_str()?.to_string(), v.unvariant().clone())))
        .collect()
}

/// An error a call ended with, or a method answers with.
#[derive(Debug, Clone, PartialEq)]
pub struct BusError {
    pub name: String,
    pub message: String,
}

impl BusError {
    pub fn new(name: &str, message: &str) -> BusError {
        BusError {
            name: name.into(),
            message: message.into(),
        }
    }
}

impl From<nova_sd::Error> for BusError {
    fn from(error: nova_sd::Error) -> BusError {
        match error {
            nova_sd::Error::Bus { name, message } => BusError { name, message },
            other => BusError {
                name: "org.freedesktop.DBus.Error.Failed".into(),
                message: other.to_string(),
            },
        }
    }
}

/// A string as JSON.
pub fn json_string(text: &str, out: &mut String) {
    out.push('"');
    for c in text.chars() {
        match c {
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn properties_read_as_conditions() {
        assert!(truthy(&Value::Bool(true)));
        assert!(!truthy(&Value::variant(Value::Bool(false))));
        assert!(!truthy(&Value::Uint32(0)));
        assert!(truthy(&Value::Uint16(720)));
        assert!(!truthy(&Value::str("")));
        assert!(truthy(&Value::str("Test iPhone")));
    }

    #[test]
    fn a_dictionary_of_variants() {
        let options = Value::options(vec![
            ("Powered", Value::Bool(true)),
            ("Alias", Value::str("Nova")),
        ]);
        let map = map_of(&options);
        assert_eq!(map.get("Powered"), Some(&Value::Bool(true)));
        assert_eq!(map.get("Alias").and_then(Value::as_str), Some("Nova"));
        assert_eq!(strings_of(&Value::strings(&["a", "B"])), vec!["a", "B"]);
        assert_eq!(bytes(&[1, 2]).as_bytes(), Some(vec![1, 2]));
    }

    #[test]
    fn json_strings() {
        let mut out = String::new();
        json_string("a\"b\\c\n\u{1}é", &mut out);
        assert_eq!(out, "\"a\\\"b\\\\c\\n\\u0001é\"");
    }
}
