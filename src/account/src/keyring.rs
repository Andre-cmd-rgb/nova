// nova-keyring-migrate: a passwordless keyring moved into the login keyring.
//
// A keyring stored without a password ("Default_keyring", say) is readable
// by anything that can read the file. nova doctor finds one, and its fix
// drops ~/.local/state/nova/keyring-migrate-pending (optionally naming
// another keyring) and runs this; nova-keyring-migrate.service runs it at a
// password unlock too. It copies every item into the password-encrypted
// login keyring, reads each one back, points the default alias at login, and
// only then deletes the old keyring and the marker. The Secret Service is
// D-Bus only: it is reached through nova-sd. Tests live in
// tests/unit/session/keyring-migrate.bats.

use std::collections::HashMap;
use std::path::PathBuf;

use nova_sd::{Bus, Value};

const SERVICE: &str = "org.freedesktop.secrets";
const ROOT: &str = "/org/freedesktop/secrets";
const LOGIN: &str = "/org/freedesktop/secrets/collection/login";
const SERVICE_IFACE: &str = "org.freedesktop.Secret.Service";
const COLLECTION_IFACE: &str = "org.freedesktop.Secret.Collection";
const ITEM_IFACE: &str = "org.freedesktop.Secret.Item";
const PROMPT_IFACE: &str = "org.freedesktop.Secret.Prompt";

/// Why it stopped, said on stderr.
struct Failed(String);

impl From<nova_sd::Error> for Failed {
    fn from(error: nova_sd::Error) -> Failed {
        Failed(match error {
            nova_sd::Error::Bus { name, message } if message.is_empty() => name,
            nova_sd::Error::Bus { message, .. } => message,
            other => other.to_string(),
        })
    }
}

fn fail<T>(message: impl Into<String>) -> Result<T, Failed> {
    Err(Failed(message.into()))
}

/// gnome-keyring's D-Bus path for a keyring file name: every byte but
/// letters and digits is escaped as _xx, as gnome-keyring escapes it.
fn object_path(keyring: &str) -> String {
    let mut escaped = String::new();
    for byte in keyring.bytes() {
        if byte.is_ascii_alphanumeric() {
            escaped.push(byte as char);
        } else {
            escaped.push_str(&format!("_{byte:02x}"));
        }
    }
    format!("{ROOT}/collection/{escaped}")
}

fn marker() -> PathBuf {
    let state = std::env::var_os("XDG_STATE_HOME")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".local/state")
        });
    state.join("nova").join("keyring-migrate-pending")
}

fn bytes(bytes: &[u8]) -> Value {
    Value::Array("y".into(), bytes.iter().map(|&b| Value::Byte(b)).collect())
}

fn paths(paths: &[String]) -> Value {
    Value::Array("o".into(), paths.iter().map(Value::path).collect())
}

/// Paths out of an array of them.
fn path_list(value: &Value) -> Vec<String> {
    value
        .as_list()
        .unwrap_or_default()
        .iter()
        .filter_map(|v| v.as_str().map(str::to_string))
        .collect()
}

/// An a{ss} dictionary as pairs, in its order.
fn string_pairs(value: &Value) -> Vec<(String, String)> {
    value
        .as_dict()
        .unwrap_or_default()
        .iter()
        .filter_map(|(k, v)| Some((k.as_str()?.to_string(), v.as_str()?.to_string())))
        .collect()
}

fn string_dict(pairs: &[(String, String)]) -> Value {
    Value::Dict(
        "s".into(),
        "s".into(),
        pairs
            .iter()
            .map(|(k, v)| (Value::str(k.as_str()), Value::str(v.as_str())))
            .collect(),
    )
}

/// A secret as GetSecrets hands it over: its value and content type.
struct Secret {
    value: Vec<u8>,
    content_type: String,
}

struct Secrets<'a> {
    bus: &'a Bus,
    session: String,
}

impl Secrets<'_> {
    fn call(
        &self,
        path: &str,
        interface: &str,
        member: &str,
        args: &[Value],
    ) -> Result<Vec<Value>, Failed> {
        Ok(self.bus.call(SERVICE, path, interface, member, args)?)
    }

    fn property(&self, path: &str, interface: &str, name: &str) -> Result<Value, Failed> {
        Ok(self.bus.get_property(SERVICE, path, interface, name)?)
    }

    fn flag(&self, path: &str, interface: &str, name: &str) -> Result<bool, Failed> {
        Ok(self
            .property(path, interface, name)?
            .as_bool()
            .unwrap_or(false))
    }

    /// The secrets of <items>, by item.
    fn secrets(&self, items: &[String]) -> Result<HashMap<String, Secret>, Failed> {
        if items.is_empty() {
            return Ok(HashMap::new());
        }
        let answer = self.call(
            ROOT,
            SERVICE_IFACE,
            "GetSecrets",
            &[paths(items), Value::path(self.session.as_str())],
        )?;
        let mut found = HashMap::new();
        for (path, secret) in answer.first().and_then(Value::as_dict).unwrap_or_default() {
            let fields = secret.as_list().unwrap_or_default();
            let (Some(path), Some(value)) =
                (path.as_str(), fields.get(2).and_then(Value::as_bytes))
            else {
                continue;
            };
            let content_type = fields
                .get(3)
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            found.insert(
                path.to_string(),
                Secret {
                    value,
                    content_type,
                },
            );
        }
        Ok(found)
    }
}

fn migrate() -> Result<(), Failed> {
    let marker = marker();
    let keyring = match std::fs::read_to_string(&marker) {
        Ok(text) => match text.trim() {
            "" => "Default_keyring".to_string(),
            name => name.to_string(),
        },
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return fail(format!("could not read {}: {error}", marker.display())),
    };
    let remove_marker = || {
        std::fs::remove_file(&marker)
            .or_else(|e| match e.kind() {
                std::io::ErrorKind::NotFound => Ok(()),
                _ => Err(e),
            })
            .map_err(|e| Failed(format!("could not remove {}: {e}", marker.display())))
    };

    let bus = Bus::user()?;
    let mut secrets = Secrets {
        bus: &bus,
        session: String::new(),
    };
    let collections = path_list(&secrets.property(ROOT, SERVICE_IFACE, "Collections")?);
    let source = object_path(&keyring);
    if !collections.contains(&source) {
        println!("nova-keyring-migrate: no keyring '{keyring}', nothing to move");
        return remove_marker();
    }
    if !collections.iter().any(|c| c == LOGIN) {
        return fail("there is no login keyring yet");
    }
    if secrets.flag(LOGIN, COLLECTION_IFACE, "Locked")? {
        return fail("the login keyring is locked");
    }
    if secrets.flag(&source, COLLECTION_IFACE, "Locked")? {
        // A keyring stored without a password reads as locked until something
        // asks to open it, which it then does without a prompt. One that needs
        // a prompt is left alone: a password dialog out of nowhere is worse.
        let answer = secrets.call(
            ROOT,
            SERVICE_IFACE,
            "Unlock",
            &[paths(std::slice::from_ref(&source))],
        )?;
        let unlocked = answer.first().map(path_list).unwrap_or_default();
        let prompt = answer.get(1).and_then(Value::as_str).unwrap_or("/");
        if prompt != "/" {
            secrets.call(prompt, PROMPT_IFACE, "Dismiss", &[])?;
        }
        if !unlocked.contains(&source) {
            return fail(format!(
                "the keyring '{keyring}' is locked, and opening it needs its password"
            ));
        }
    }

    let opened = secrets.call(
        ROOT,
        SERVICE_IFACE,
        "OpenSession",
        &[Value::str("plain"), Value::variant(Value::str(""))],
    )?;
    secrets.session = opened
        .get(1)
        .and_then(Value::as_str)
        .unwrap_or("/")
        .to_string();

    let items = path_list(&secrets.property(&source, COLLECTION_IFACE, "Items")?);
    let found = secrets.secrets(&items)?;
    let mut moved: Vec<(String, Vec<u8>)> = Vec::new();
    let mut kept = 0;
    // Apps write to the keyring the default alias names. A secret the login
    // keyring has as well is newer in the one moved while that is the one it
    // names, and replaces login's then; otherwise login's is the newer, and
    // stays: a stale Chrome key put over it would lose every saved password.
    let default = secrets.call(ROOT, SERVICE_IFACE, "ReadAlias", &[Value::str("default")])?;
    let moved_is_default = default.first().and_then(Value::as_str) == Some(source.as_str());
    for path in &items {
        let Some(secret) = found.get(path) else {
            return fail(format!("could not read {path}"));
        };
        let label = secrets.property(path, ITEM_IFACE, "Label")?;
        let label = label.as_str().unwrap_or("").to_string();
        let attributes = string_pairs(&secrets.property(path, ITEM_IFACE, "Attributes")?);
        // The same secret, whichever schema its keyring gave it.
        let same: Vec<(String, String)> = attributes
            .iter()
            .filter(|(k, _)| k != "xdg:schema")
            .cloned()
            .collect();
        if !moved_is_default && !same.is_empty() {
            let answer = secrets.call(
                LOGIN,
                COLLECTION_IFACE,
                "SearchItems",
                &[string_dict(&same)],
            )?;
            if !answer.first().map(path_list).unwrap_or_default().is_empty() {
                kept += 1;
                continue;
            }
        }
        let properties = Value::options(vec![
            (format!("{ITEM_IFACE}.Label"), Value::str(label.as_str())),
            (format!("{ITEM_IFACE}.Attributes"), string_dict(&attributes)),
        ]);
        let value = Value::Struct(vec![
            Value::path(secrets.session.as_str()),
            bytes(b""),
            bytes(&secret.value),
            Value::str(secret.content_type.as_str()),
        ]);
        let created = secrets.call(
            LOGIN,
            COLLECTION_IFACE,
            "CreateItem",
            &[properties, value, Value::Bool(true)],
        )?;
        let created = created.first().and_then(Value::as_str).unwrap_or("/");
        if created == "/" {
            return fail(format!("the login keyring refused '{label}'"));
        }
        moved.push((created.to_string(), secret.value.clone()));
    }

    // Read every copy back before anything is deleted.
    let copies: Vec<String> = moved.iter().map(|(path, _)| path.clone()).collect();
    let copies = secrets.secrets(&copies)?;
    for (path, value) in &moved {
        if copies.get(path).map(|c| &c.value) != Some(value) {
            return fail(format!(
                "{path} did not read back the same; the old keyring is kept"
            ));
        }
    }

    secrets.call(
        ROOT,
        SERVICE_IFACE,
        "SetAlias",
        &[Value::str("default"), Value::path(LOGIN)],
    )?;
    let deleted = secrets.call(&source, COLLECTION_IFACE, "Delete", &[])?;
    if deleted.first().and_then(Value::as_str).unwrap_or("/") != "/" {
        return fail(format!("deleting '{keyring}' needs a prompt; it is kept"));
    }
    remove_marker()?;
    println!(
        "nova-keyring-migrate: moved {} secrets from '{keyring}' into login",
        moved.len()
    );
    if kept > 0 {
        println!(
            "nova-keyring-migrate: kept login's own {kept}, which were newer than '{keyring}''s"
        );
    }
    Ok(())
}

fn main() {
    if let Err(Failed(message)) = migrate() {
        eprintln!("nova-keyring-migrate: {message}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keyring_paths_as_gnome_keyring_escapes_them() {
        assert_eq!(
            object_path("Default_keyring"),
            "/org/freedesktop/secrets/collection/Default_5fkeyring"
        );
        assert_eq!(object_path("login"), LOGIN);
        // By its UTF-8 bytes, as gnome-keyring escapes a name.
        assert_eq!(
            object_path("clé 1"),
            "/org/freedesktop/secrets/collection/cl_c3_a9_201"
        );
    }
}
