//! The shell's allocator settings, for Quickshell alone.
//!
//! Quickshell allocates with jemalloc, which gives threads arenas of their
//! own, four per CPU: 64 on a 16-thread laptop, more than the shell's
//! twenty-odd threads (Qt's, Mesa's), so each kept the pages of its own. Two
//! arenas for all of them hold the same shell in a third less, and its
//! windows open as fast.
//!
//! Nor are the arenas' pages made huge. With transparent huge pages on for
//! everything, as Arch's kernel has them, the kernel backs a 2 MB stretch of
//! an arena with one huge page as soon as it is touched, and the part of it
//! jemalloc never fills is held all the same: 60 MB of the shell's memory
//! was in huge pages, 8 MB once jemalloc asks for none.
//!
//! What each took, measured on 2026-11-21: the proportional set size of the
//! shell at rest, 40 s after it started, on a nested Hyprland at the P1's
//! 3840x2400 and scale 1.6, adaptive theme, the dusk background, no buses
//! (so no devices); the same each run within 1 MB.
//!
//!     jemalloc's own settings (64 arenas)    218 MB
//!     narenas:2                              150 MB
//!     narenas:2,thp:never                    144 MB
//!
//! Returning freed pages sooner (dirty_decay_ms:1000,muzzy_decay_ms:0) took
//! nothing off at rest, and is not set.
//!
//! The setting is the program's own `malloc_conf`, which jemalloc reads
//! before /etc/malloc.conf and MALLOC_CONF, so either still has the last
//! word. nova-launch-shell preloads this library into Quickshell, whose
//! `malloc_conf` this one becomes, and as it loads it takes itself out of
//! LD_PRELOAD. In MALLOC_CONF the setting would reach every app the shell
//! starts, as they inherit its environment (nova-launch's scope, the menu, a
//! notification's action), and hold to two arenas any of them built on
//! jemalloc, however many threads it runs.
//!
//! The library also has Qt draw the shell's windows without a depth or a
//! stencil buffer. A Qt Quick window gets both by default, a 24-bit depth and
//! an 8-bit stencil buffer the window's size (Mesa has no config with one
//! and not the other), and the shell needs neither: Qt's 2D renderer uses
//! depth only to skip covered pixels of opaque items, and stencil only to
//! clip an item that is rotated, which no clipped item of the shell is
//! (scissors clip the rest). The background's window, the size of the
//! screen, held 58 MiB of them at 3840x2400: its graphics memory went from
//! 238 MiB to 176 MiB, five runs each, every picture of the bar's panels, the
//! menu, Settings and the lock the same but for the clock (same harness as
//! above, Intel's iris driver).
//!
//! Qt reads QSG_NO_DEPTH_BUFFER and QSG_NO_STENCIL_BUFFER once, through
//! getenv(), when the first window is made. In the environment they would
//! reach every app the shell starts, and a Qt app that clips a rotated item
//! or draws 3D into its window needs those buffers. So this library's
//! getenv() answers "1" for those two names when the environment does not
//! have them, and is libc's for everything else: they are the shell's alone.
//! Either name in the environment, even empty, is the environment's:
//! `QSG_NO_STENCIL_BUFFER=` gives the shell its buffers back.

use std::ffi::{c_char, CStr, OsStr, OsString};
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::path::Path;

/// A C string, as jemalloc reads it.
#[repr(transparent)]
pub struct Conf(*const c_char);

// SAFETY: it points at a string in the library's own read-only data, which
// nothing writes.
unsafe impl Sync for Conf {}

/// jemalloc's options for the program, in MALLOC_CONF's syntax.
#[allow(non_upper_case_globals)]
#[no_mangle]
pub static malloc_conf: Conf = Conf(c"narenas:2,thp:never".as_ptr());

/// The library's file name, as it is built and installed.
const OWN: &str = "libnova_shell_alloc.so";

// Runs as the library loads, before Quickshell's main() and before any
// thread, so nothing else is reading the environment as it changes.
#[used]
#[link_section = ".init_array"]
static LEAVE_PRELOAD: extern "C" fn() = leave_preload;

extern "C" fn leave_preload() {
    let Some(list) = std::env::var_os("LD_PRELOAD") else {
        return;
    };
    match without_own(&list) {
        None => {}
        Some(rest) if rest.is_empty() => std::env::remove_var("LD_PRELOAD"),
        Some(rest) => std::env::set_var("LD_PRELOAD", rest),
    }
}

/// What the shell's getenv() answers for a name the environment lacks.
const SHELL_ONLY: [(&CStr, &CStr); 2] = [
    (c"QSG_NO_DEPTH_BUFFER", c"1"),
    (c"QSG_NO_STENCIL_BUFFER", c"1"),
];

extern "C" {
    // glibc's setenv()/unsetenv() (including leave_preload) can reassign
    // `environ`, so it must be `static mut` and read through a raw pointer.
    static mut environ: *const *const c_char;
}

/// The value of <name> in <env> ("NAME=value" entries), or None.
fn lookup<'a>(env: impl IntoIterator<Item = &'a CStr>, name: &[u8]) -> Option<&'a CStr> {
    env.into_iter().find_map(|entry| {
        let bytes = entry.to_bytes();
        (bytes.len() > name.len() && bytes.starts_with(name) && bytes[name.len()] == b'=')
            // SAFETY: what is after the '=' is the rest of a C string.
            .then(|| unsafe { CStr::from_ptr(entry.as_ptr().add(name.len() + 1)) })
    })
}

/// The shell's own value of <name>, for when the environment has none.
fn shell_only(name: &[u8]) -> Option<&'static CStr> {
    SHELL_ONLY
        .iter()
        .find(|(key, _)| key.to_bytes() == name)
        .map(|(_, value)| *value)
}

/// libc's getenv(), with the values above for the names in SHELL_ONLY. It
/// reads `environ` itself, as libc's does, and allocates nothing: the first
/// calls come before main(), jemalloc's among them.
///
/// # Safety
///
/// As libc's: <name> is a C string, and nothing changes the environment
/// meanwhile. The string returned is not to be written to.
#[no_mangle]
pub unsafe extern "C" fn getenv(name: *const c_char) -> *mut c_char {
    if name.is_null() {
        return std::ptr::null_mut();
    }
    // SAFETY: the caller's C string; environ is libc's, a list of C strings
    // ended by a null, or null itself. Read through a raw pointer rather
    // than taking a reference to a static mut.
    let name = unsafe { CStr::from_ptr(name) }.to_bytes();
    let mut entries = unsafe { std::ptr::addr_of!(environ).read() };
    let env = std::iter::from_fn(|| {
        // SAFETY: as above; the walk stops at the null.
        let entry = unsafe { entries.as_ref().map(|first| *first) }?;
        if entry.is_null() {
            return None;
        }
        entries = unsafe { entries.add(1) };
        Some(unsafe { CStr::from_ptr(entry) })
    });
    match lookup(env, name).or_else(|| shell_only(name)) {
        Some(value) => value.as_ptr() as *mut c_char,
        None => std::ptr::null_mut(),
    }
}

/// LD_PRELOAD without this library, or None when it is not in it. ld.so
/// splits the list at spaces and colons; what is left is joined by colons.
fn without_own(list: &OsStr) -> Option<OsString> {
    let entries = list
        .as_bytes()
        .split(|b| *b == b' ' || *b == b':')
        .filter(|entry| !entry.is_empty());
    let (own, rest): (Vec<&[u8]>, Vec<&[u8]>) = entries.partition(|entry| {
        Path::new(OsStr::from_bytes(entry)).file_name() == Some(OsStr::new(OWN))
    });
    if own.is_empty() {
        return None;
    }
    Some(OsString::from_vec(rest.join(&b':')))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn strip(list: &str) -> Option<String> {
        without_own(OsStr::new(list)).map(|rest| rest.into_string().unwrap())
    }

    #[test]
    fn alone_it_leaves_nothing() {
        assert_eq!(
            strip("/usr/lib/nova/libnova_shell_alloc.so").as_deref(),
            Some("")
        );
    }

    #[test]
    fn another_library_stays_for_the_apps() {
        assert_eq!(
            strip("/usr/lib/nova/libnova_shell_alloc.so:/opt/other.so").as_deref(),
            Some("/opt/other.so")
        );
        assert_eq!(
            strip("/opt/a.so /usr/lib/nova/libnova_shell_alloc.so  /opt/b.so").as_deref(),
            Some("/opt/a.so:/opt/b.so")
        );
    }

    #[test]
    fn a_list_without_it_is_left_as_it_was() {
        assert_eq!(strip("/opt/a.so /opt/b.so"), None);
        assert_eq!(strip("/opt/libnova_shell_alloc.so.old"), None);
        assert_eq!(strip(""), None);
    }

    fn env(entries: &[&'static CStr]) -> Vec<&'static CStr> {
        entries.to_vec()
    }

    fn value(found: Option<&CStr>) -> Option<&str> {
        found.map(|v| v.to_str().unwrap())
    }

    #[test]
    fn a_name_is_found_whole_and_not_by_its_start() {
        let e = env(&[c"QSG_NO_DEPTH_BUFFER_X=7", c"PATH=/usr/bin", c"EMPTY="]);
        assert_eq!(value(lookup(e.iter().copied(), b"PATH")), Some("/usr/bin"));
        assert_eq!(value(lookup(e.iter().copied(), b"EMPTY")), Some(""));
        assert_eq!(
            value(lookup(e.iter().copied(), b"QSG_NO_DEPTH_BUFFER")),
            None
        );
        assert_eq!(value(lookup(e.iter().copied(), b"PAT")), None);
    }

    #[test]
    fn qt_is_told_no_depth_and_no_stencil_buffer_unless_the_environment_says() {
        assert_eq!(value(shell_only(b"QSG_NO_DEPTH_BUFFER")), Some("1"));
        assert_eq!(value(shell_only(b"QSG_NO_STENCIL_BUFFER")), Some("1"));
        assert_eq!(value(shell_only(b"QSG_INFO")), None);
        // Through the getenv() itself: the test's environment has neither
        // name unless someone set it, and has PATH.
        let read = |name: &CStr| {
            // SAFETY: a C string; the tests change no environment.
            let found = unsafe { getenv(name.as_ptr()) };
            (!found.is_null()).then(|| {
                unsafe { CStr::from_ptr(found) }
                    .to_str()
                    .unwrap()
                    .to_owned()
            })
        };
        if std::env::var_os("QSG_NO_STENCIL_BUFFER").is_none() {
            assert_eq!(read(c"QSG_NO_STENCIL_BUFFER").as_deref(), Some("1"));
        }
        assert_eq!(read(c"PATH"), std::env::var("PATH").ok());
        assert_eq!(read(c"NOVA_SURELY_UNSET_NAME"), None);
    }

    #[test]
    fn the_setting_is_what_jemalloc_is_given() {
        // SAFETY: the pointer is the literal's, which lives for the program.
        let conf = unsafe { std::ffi::CStr::from_ptr(malloc_conf.0) };
        assert_eq!(conf.to_str().unwrap(), "narenas:2,thp:never");
    }

    #[test]
    fn environ_is_mutable_as_libc_changes_it() {
        // Fails to compile if `environ` is declared immutable (UB when glibc's
        // setenv/unsetenv, including leave_preload, updates it).
        let slot: *mut *const *const c_char = std::ptr::addr_of_mut!(environ);
        assert!(!slot.is_null());
    }
}
