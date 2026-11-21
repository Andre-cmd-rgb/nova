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

use std::ffi::{c_char, OsStr, OsString};
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

    #[test]
    fn the_setting_is_what_jemalloc_is_given() {
        // SAFETY: the pointer is the literal's, which lives for the program.
        let conf = unsafe { std::ffi::CStr::from_ptr(malloc_conf.0) };
        assert_eq!(conf.to_str().unwrap(), "narenas:2,thp:never");
    }
}
