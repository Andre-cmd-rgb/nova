//! What the window needs to show a file: its name, its type in the system's
//! words, its size, a folder's items and its icon's names. All of it is
//! GIO's: the content type from shared-mime-info as Files sees it, the
//! type's description, the themed icon, the size as GLib writes it, and any
//! URI GIO's modules can reach (an SFTP share through GVfs, say).

use std::ffi::{c_char, c_int, c_void, CStr, CString};

#[repr(C)]
struct GError {
    domain: u32,
    code: c_int,
    message: *const c_char,
}

type GType = usize;

#[link(name = "gio-2.0")]
#[link(name = "gobject-2.0")]
#[link(name = "glib-2.0")]
extern "C" {
    fn g_file_new_for_uri(uri: *const c_char) -> *mut c_void;
    fn g_file_get_path(file: *mut c_void) -> *mut c_char;
    fn g_file_get_basename(file: *mut c_void) -> *mut c_char;
    fn g_file_query_info(
        file: *mut c_void,
        attributes: *const c_char,
        flags: c_int,
        cancellable: *mut c_void,
        error: *mut *mut GError,
    ) -> *mut c_void;
    fn g_file_enumerate_children(
        file: *mut c_void,
        attributes: *const c_char,
        flags: c_int,
        cancellable: *mut c_void,
        error: *mut *mut GError,
    ) -> *mut c_void;
    fn g_file_enumerator_next_file(
        enumerator: *mut c_void,
        cancellable: *mut c_void,
        error: *mut *mut GError,
    ) -> *mut c_void;
    fn g_file_info_get_display_name(info: *mut c_void) -> *const c_char;
    fn g_file_info_get_content_type(info: *mut c_void) -> *const c_char;
    fn g_file_info_get_size(info: *mut c_void) -> i64;
    fn g_file_info_get_file_type(info: *mut c_void) -> c_int;
    fn g_file_info_get_icon(info: *mut c_void) -> *mut c_void;
    fn g_file_info_get_is_hidden(info: *mut c_void) -> c_int;
    fn g_themed_icon_get_type() -> GType;
    fn g_themed_icon_get_names(icon: *mut c_void) -> *const *const c_char;
    fn g_type_check_instance_is_a(instance: *mut c_void, type_: GType) -> c_int;
    fn g_content_type_get_description(content_type: *const c_char) -> *mut c_char;
    fn g_content_type_is_a(content_type: *const c_char, supertype: *const c_char) -> c_int;
    fn g_format_size(size: u64) -> *mut c_char;
    fn g_object_unref(object: *mut c_void);
    fn g_free(memory: *mut c_void);
    fn g_error_free(error: *mut GError);
}

const G_FILE_TYPE_DIRECTORY: c_int = 2;

/// A GObject of GIO's, unreferenced when it goes.
struct Object(*mut c_void);

impl Drop for Object {
    fn drop(&mut self) {
        if !self.0.is_null() {
            // SAFETY: a reference this owns, given up once.
            unsafe { g_object_unref(self.0) };
        }
    }
}

/// A string GLib gave and wants freed, as Rust's.
fn owned(text: *mut c_char) -> Option<String> {
    if text.is_null() {
        return None;
    }
    // SAFETY: a NUL-terminated string GLib allocated, read once and freed here.
    let value = unsafe { CStr::from_ptr(text) }
        .to_string_lossy()
        .into_owned();
    // SAFETY: GLib's allocation, freed with GLib's free.
    unsafe { g_free(text.cast()) };
    Some(value)
}

/// A string GLib gave and wants freed, as Rust's if it is UTF-8 as it
/// stands; freed either way.
fn owned_exact(text: *mut c_char) -> Option<String> {
    if text.is_null() {
        return None;
    }
    // SAFETY: a NUL-terminated string GLib allocated, read once and freed here.
    let value = unsafe { CStr::from_ptr(text) }
        .to_str()
        .ok()
        .map(str::to_owned);
    // SAFETY: GLib's allocation, freed with GLib's free.
    unsafe { g_free(text.cast()) };
    value
}

/// A string GLib keeps, as Rust's.
fn borrowed(text: *const c_char) -> Option<String> {
    if text.is_null() {
        return None;
    }
    // SAFETY: a NUL-terminated string that lives as long as its owner, which is alive here.
    Some(
        unsafe { CStr::from_ptr(text) }
            .to_string_lossy()
            .into_owned(),
    )
}

fn forget(error: *mut GError) {
    if !error.is_null() {
        // SAFETY: an error GIO set, freed once.
        unsafe { g_error_free(error) };
    }
}

/// What a file is shown as.
#[derive(Debug, Clone, PartialEq)]
pub struct Description {
    pub uri: String,
    pub path: String,
    pub name: String,
    pub kind: &'static str,
    pub mime: String,
    pub kind_text: String,
    pub size: i64,
    pub size_text: String,
    pub items: i64,
    pub icon: Vec<String>,
}

/// Text is anything that is plain text underneath: source code,
/// configuration, logs.
const TEXT_TYPES: [&str; 3] = ["text/plain", "application/json", "application/xml"];

fn kind_of(content_type: &str, directory: bool) -> &'static str {
    if directory {
        return "folder";
    }
    if content_type == "application/pdf" {
        return "pdf";
    }
    for prefix in ["image", "video", "audio"] {
        if content_type.starts_with(prefix) && content_type[prefix.len()..].starts_with('/') {
            return prefix;
        }
    }
    let Ok(this) = CString::new(content_type) else {
        return "other";
    };
    let text = TEXT_TYPES.iter().any(|t| {
        let t = CString::new(*t).unwrap();
        // SAFETY: two NUL-terminated content types.
        unsafe { g_content_type_is_a(this.as_ptr(), t.as_ptr()) != 0 }
    });
    if text {
        "text"
    } else {
        "other"
    }
}

/// How many items a folder has, hidden ones left out as Files does; -1 when
/// it cannot be read.
fn count_items(file: &Object) -> i64 {
    let attributes = c"standard::is-hidden";
    let mut error = std::ptr::null_mut();
    // SAFETY: a GFile this holds; the error is set or the enumerator returned.
    let children = Object(unsafe {
        g_file_enumerate_children(
            file.0,
            attributes.as_ptr(),
            0,
            std::ptr::null_mut(),
            &mut error,
        )
    });
    if children.0.is_null() {
        forget(error);
        return -1;
    }
    let mut total = 0;
    loop {
        let mut error = std::ptr::null_mut();
        // SAFETY: the enumerator this holds; a GFileInfo it owns comes back, or null at the end or on an error.
        let info = Object(unsafe {
            g_file_enumerator_next_file(children.0, std::ptr::null_mut(), &mut error)
        });
        if info.0.is_null() {
            if !error.is_null() {
                forget(error);
                return -1;
            }
            return total;
        }
        // SAFETY: a GFileInfo with standard::is-hidden queried.
        if unsafe { g_file_info_get_is_hidden(info.0) } == 0 {
            total += 1;
        }
    }
}

/// The size as Files writes it: "8 bytes", "1.2 MB".
pub fn size_text(size: u64) -> String {
    // SAFETY: no pointers in; a string GLib allocated comes back.
    owned(unsafe { g_format_size(size) }).unwrap_or_default()
}

/// What the window needs to show <uri>.
pub fn describe(uri: &str) -> Description {
    let c_uri = CString::new(uri.replace('\0', "")).unwrap();
    // SAFETY: a NUL-terminated URI; GIO returns a new GFile, never null.
    let file = Object(unsafe { g_file_new_for_uri(c_uri.as_ptr()) });
    // SAFETY: the GFile this holds; each returns a string to free, or null.
    // A path that is not UTF-8 would reach the shell with replacement
    // characters and name no file; without one the window shows its plain
    // page, and Open still has the URI.
    let path = owned_exact(unsafe { g_file_get_path(file.0) }).unwrap_or_default();
    let basename = owned(unsafe { g_file_get_basename(file.0) }).filter(|n| !n.is_empty());
    let mut out = Description {
        uri: uri.to_string(),
        path,
        name: basename.unwrap_or_else(|| uri.to_string()),
        kind: "other",
        mime: String::new(),
        kind_text: String::new(),
        size: -1,
        size_text: String::new(),
        items: -1,
        icon: vec!["text-x-generic".into()],
    };
    let attributes = c"standard::display-name,standard::content-type,standard::size,standard::type,standard::icon";
    let mut error = std::ptr::null_mut();
    // SAFETY: the GFile this holds, NUL-terminated attributes; an info or an error comes back.
    let info = Object(unsafe {
        g_file_query_info(
            file.0,
            attributes.as_ptr(),
            0,
            std::ptr::null_mut(),
            &mut error,
        )
    });
    if info.0.is_null() {
        // Gone, or not reachable: the name and a plain page are still shown.
        forget(error);
        return out;
    }
    // SAFETY: the GFileInfo holds these attributes, asked for above; its strings live as long as it.
    let content_type = borrowed(unsafe { g_file_info_get_content_type(info.0) })
        .filter(|t| !t.is_empty())
        .unwrap_or_else(|| "application/octet-stream".into());
    // SAFETY: as above.
    let directory = unsafe { g_file_info_get_file_type(info.0) } == G_FILE_TYPE_DIRECTORY;
    out.kind = kind_of(&content_type, directory);
    // SAFETY: as above.
    if let Some(name) = borrowed(unsafe { g_file_info_get_display_name(info.0) }) {
        if !name.is_empty() {
            out.name = name;
        }
    }
    let c_type = CString::new(content_type.as_str()).unwrap();
    // SAFETY: a NUL-terminated content type; a string to free comes back.
    out.kind_text =
        owned(unsafe { g_content_type_get_description(c_type.as_ptr()) }).unwrap_or_default();
    out.mime = content_type;
    // SAFETY: the icon is the info's (not ours to unref); a themed icon's names live as long as it.
    unsafe {
        let icon = g_file_info_get_icon(info.0);
        if !icon.is_null() && g_type_check_instance_is_a(icon, g_themed_icon_get_type()) != 0 {
            let names = g_themed_icon_get_names(icon);
            let mut found = Vec::new();
            let mut at = 0;
            while !names.is_null() && !(*names.add(at)).is_null() {
                found.extend(borrowed(*names.add(at)));
                at += 1;
            }
            out.icon = found;
        }
    }
    if directory {
        out.items = count_items(&file);
    } else {
        // SAFETY: standard::size was asked for.
        out.size = unsafe { g_file_info_get_size(info.0) };
        out.size_text = size_text(out.size.max(0) as u64);
    }
    out
}

/// A string as JSON.
fn json_string(text: &str, out: &mut String) {
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

impl Description {
    /// The one line of JSON the shell is handed, with the window's <seq>.
    pub fn json(&self, seq: u32) -> String {
        let mut out = String::from("{");
        let field = |name: &str, out: &mut String| {
            if out.len() > 1 {
                out.push_str(", ");
            }
            json_string(name, out);
            out.push_str(": ");
        };
        for (name, value) in [
            ("uri", &self.uri),
            ("path", &self.path),
            ("name", &self.name),
        ] {
            field(name, &mut out);
            json_string(value, &mut out);
        }
        field("kind", &mut out);
        json_string(self.kind, &mut out);
        field("mime", &mut out);
        json_string(&self.mime, &mut out);
        field("type", &mut out);
        json_string(&self.kind_text, &mut out);
        field("size", &mut out);
        out.push_str(&self.size.to_string());
        field("sizeText", &mut out);
        json_string(&self.size_text, &mut out);
        field("items", &mut out);
        out.push_str(&self.items.to_string());
        field("icon", &mut out);
        out.push('[');
        for (at, name) in self.icon.iter().enumerate() {
            if at > 0 {
                out.push_str(", ");
            }
            json_string(name, &mut out);
        }
        out.push(']');
        field("seq", &mut out);
        out.push_str(&seq.to_string());
        out.push('}');
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(name: &str) -> std::path::PathBuf {
        let dir =
            std::env::temp_dir().join(format!("nova-previewer-test-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn a_text_file_is_described_by_gio() {
        let dir = scratch("text");
        let file = dir.join("notes.txt");
        std::fs::write(&file, "one\ntwo\n").unwrap();
        let uri = format!("file://{}", file.display());
        let info = describe(&uri);
        assert_eq!(info.path, file.display().to_string());
        assert_eq!(info.name, "notes.txt");
        assert_eq!(info.kind, "text");
        assert_eq!(info.mime, "text/plain");
        assert_eq!(info.size, 8);
        assert_eq!(info.size_text, "8 bytes");
        assert_eq!(info.items, -1);
        assert!(!info.kind_text.is_empty());
        assert!(info
            .icon
            .iter()
            .any(|n| n == "text-plain" || n == "text-x-generic"));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn a_path_that_is_not_utf8_is_left_out_and_the_uri_kept() {
        use std::os::unix::ffi::OsStrExt;
        let dir = scratch("bytes");
        let file = dir.join(std::ffi::OsStr::from_bytes(b"caf\xe9.txt"));
        std::fs::write(&file, "x").unwrap();
        let uri = format!("file://{}/caf%E9.txt", dir.display());
        let info = describe(&uri);
        assert_eq!(info.path, "");
        assert_eq!(info.uri, uri);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn a_folder_counts_its_visible_items() {
        let dir = scratch("folder");
        let folder = dir.join("stuff");
        std::fs::create_dir(&folder).unwrap();
        for name in ["a", "b", ".hidden"] {
            std::fs::write(folder.join(name), "").unwrap();
        }
        let info = describe(&format!("file://{}", folder.display()));
        assert_eq!(info.kind, "folder");
        assert_eq!(info.items, 2);
        assert_eq!(info.size, -1);
        assert_eq!(info.mime, "inode/directory");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn a_file_that_is_gone_keeps_its_name() {
        let info = describe("file:///nonexistent/nova/gone.bin");
        assert_eq!(info.name, "gone.bin");
        assert_eq!(info.kind, "other");
        assert_eq!(info.path, "/nonexistent/nova/gone.bin");
        assert_eq!(info.icon, vec!["text-x-generic".to_string()]);
    }

    #[test]
    fn kinds_by_content_type() {
        assert_eq!(kind_of("application/pdf", false), "pdf");
        assert_eq!(kind_of("image/png", false), "image");
        assert_eq!(kind_of("video/mp4", false), "video");
        assert_eq!(kind_of("audio/flac", false), "audio");
        assert_eq!(kind_of("imagex/png", false), "other");
        assert_eq!(kind_of("application/json", false), "text");
        assert_eq!(kind_of("text/x-python", false), "text");
        assert_eq!(kind_of("application/zip", false), "other");
        assert_eq!(kind_of("inode/directory", true), "folder");
    }

    #[test]
    fn the_line_for_the_shell() {
        let info = Description {
            uri: "file:///a/\"b\".txt".into(),
            path: "/a/\"b\".txt".into(),
            name: "\"b\".txt".into(),
            kind: "text",
            mime: "text/plain".into(),
            kind_text: "plain text document".into(),
            size: 8,
            size_text: "8 bytes".into(),
            items: -1,
            icon: vec!["text-plain".into(), "text-x-generic".into()],
        };
        assert_eq!(
            info.json(3),
            r#"{"uri": "file:///a/\"b\".txt", "path": "/a/\"b\".txt", "name": "\"b\".txt", "kind": "text", "mime": "text/plain", "type": "plain text document", "size": 8, "sizeText": "8 bytes", "items": -1, "icon": ["text-plain", "text-x-generic"], "seq": 3}"#
        );
    }
}
