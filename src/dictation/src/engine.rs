//! The speech engine: NVIDIA's Parakeet TDT, through whisper.cpp's
//! libparakeet (Nova's own whisper-cpp package, packaging/whisper-cpp).
//!
//! The library is opened when a dictation first needs it, not linked: the
//! nova package builds and tests where whisper-cpp is not installed, and a
//! computer without it is told so. Its functions are declared here as
//! whisper.cpp 1.9.5's include/parakeet.h declares them (VERSION), and two
//! of them take or give a struct by value. The soname says nothing of that
//! layout: it is the major version only (libparakeet.so.1 for every 1.x),
//! and parakeet_full_params changes between minor releases. So the library
//! is asked its version as it is opened, and one of another release is no
//! engine, said so, rather than handed a struct it reads otherwise.
//!
//! ggml, under it, is built with one CPU backend for each generation of x86
//! CPU (libggml-cpu-*.so beside the library), and the best one this CPU can
//! run is loaded by ggml_backend_load_all() before the model, as
//! parakeet-cli does. Without that call there is no backend at all, and the
//! model does not load; `Engine::backend` names the one in use, which the
//! daemon logs, so that a generic build in place of AVX-512's (several times
//! slower) would show.

use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::OnceLock;

/// Where Nova's whisper-cpp puts the library.
pub const LIBRARY: &str = "/usr/lib/whisper-cpp/libparakeet.so.1";

/// The whisper.cpp release whose include/parakeet.h this file follows,
/// field for field: packaging/whisper-cpp/PKGBUILD's pkgver (a test ties
/// the two). Moving the package to another release means checking every
/// declaration below against its header, then this.
pub const VERSION: &str = "1.9.5";

/// Whether parakeet_version()'s <version> is VERSION. whisper.cpp's build
/// adds "-dev" unless WHISPER_BUILD_IS_DEV is off, which Nova's package
/// leaves on, as upstream's release does: its 1.9.5 says "1.9.5-dev".
pub fn known(version: &str) -> bool {
    version.strip_suffix("-dev").unwrap_or(version) == VERSION
}

/// Whether the library at <path> is a speech engine this can use: there,
/// and of the release it was written for (why not, if not). Of its code,
/// only its version runs, and what runs as it is loaded: its constructors
/// and those of the libraries it brings.
pub fn check(path: &str) -> Result<(), String> {
    Library::open(path).map(drop)
}

/// The engine's samples: 16 kHz, mono.
pub const RATE: usize = 16_000;

extern "C" {
    fn dlopen(name: *const c_char, flags: c_int) -> *mut c_void;
    fn dlsym(handle: *mut c_void, symbol: *const c_char) -> *mut c_void;
    fn dlerror() -> *const c_char;
}
const RTLD_NOW: c_int = 2;
const RTLD_LOCAL: c_int = 0;

/// struct parakeet_context_params.
#[repr(C)]
#[derive(Clone, Copy)]
struct ContextParams {
    use_gpu: bool,
    gpu_device: c_int,
}

type AbortCallback = unsafe extern "C" fn(data: *mut c_void) -> bool;
type LogCallback = unsafe extern "C" fn(level: c_int, text: *const c_char, data: *mut c_void);

/// struct parakeet_full_params, field for field.
#[repr(C)]
#[derive(Clone, Copy)]
struct FullParams {
    strategy: c_int,
    n_threads: c_int,
    offset_ms: c_int,
    duration_ms: c_int,
    no_context: bool,
    audio_ctx: c_int,
    new_segment_callback: *const c_void,
    new_segment_callback_user_data: *mut c_void,
    new_token_callback: *const c_void,
    new_token_callback_user_data: *mut c_void,
    progress_callback: *const c_void,
    progress_callback_user_data: *mut c_void,
    encoder_begin_callback: *const c_void,
    encoder_begin_callback_user_data: *mut c_void,
    abort_callback: Option<AbortCallback>,
    abort_callback_user_data: *mut c_void,
}

/// parakeet_token_data.
#[repr(C)]
#[derive(Clone, Copy)]
struct TokenData {
    id: i32,
    duration_idx: c_int,
    duration_value: c_int,
    frame_index: c_int,
    p: f32,
    plog: f32,
    t0: i64,
    t1: i64,
    is_word_start: bool,
}

const SAMPLING_GREEDY: c_int = 0;
const GGML_LOG_LEVEL_WARN: c_int = 3;
const GGML_LOG_LEVEL_CONT: c_int = 5;

/// The functions of libparakeet (and of the ggml it brings) this uses.
struct Library {
    backend_load_all: unsafe extern "C" fn(),
    log_set: unsafe extern "C" fn(Option<LogCallback>, *mut c_void),
    context_default_params: unsafe extern "C" fn() -> ContextParams,
    init_from_file: unsafe extern "C" fn(*const c_char, ContextParams) -> *mut c_void,
    free: unsafe extern "C" fn(*mut c_void),
    full_default_params: unsafe extern "C" fn(c_int) -> FullParams,
    full: unsafe extern "C" fn(*mut c_void, FullParams, *const f32, c_int) -> c_int,
    n_segments: unsafe extern "C" fn(*mut c_void) -> c_int,
    n_tokens: unsafe extern "C" fn(*mut c_void, c_int) -> c_int,
    token_data: unsafe extern "C" fn(*mut c_void, c_int, c_int) -> TokenData,
    token_to_str: unsafe extern "C" fn(*mut c_void, i32) -> *const c_char,
}

// The library's own lines (its model's every parameter as it loads) are
// left out; its warnings and errors go to the journal. A line may come in
// parts (GGML_LOG_LEVEL_CONT), kept with the level of the first.
static LOUD: AtomicBool = AtomicBool::new(false);

unsafe extern "C" fn log(level: c_int, text: *const c_char, _data: *mut c_void) {
    let loud = if level == GGML_LOG_LEVEL_CONT {
        LOUD.load(Ordering::Relaxed)
    } else {
        let loud = level >= GGML_LOG_LEVEL_WARN;
        LOUD.store(loud, Ordering::Relaxed);
        loud
    };
    if loud && !text.is_null() {
        // SAFETY: ggml passes a NUL-terminated line.
        let line = unsafe { CStr::from_ptr(text) }.to_string_lossy();
        eprint!("nova-dictationd: engine: {line}");
    }
}

impl Library {
    #[allow(clippy::missing_transmute_annotations)]
    fn open(path: &str) -> Result<Library, String> {
        let name = CString::new(path).map_err(|_| "a library path with a NUL".to_owned())?;
        // SAFETY: a NUL-terminated path; the library stays loaded for the life of the process.
        let handle = unsafe { dlopen(name.as_ptr(), RTLD_NOW | RTLD_LOCAL) };
        if handle.is_null() {
            // SAFETY: dlerror's message, if any, is NUL-terminated and ours to read now.
            let why = unsafe { dlerror() };
            let why = if why.is_null() {
                String::new()
            } else {
                // SAFETY: as above.
                unsafe { CStr::from_ptr(why) }
                    .to_string_lossy()
                    .into_owned()
            };
            return Err(format!("no speech engine ({path}): {why}"));
        }
        // A symbol of libparakeet, or of the libggml it brought: dlsym on a
        // handle looks through the libraries loaded with it.
        macro_rules! symbol {
            ($name:literal) => {{
                let name = CString::new($name).unwrap();
                // SAFETY: the handle is a loaded library's; the name is NUL-terminated.
                let found = unsafe { dlsym(handle, name.as_ptr()) };
                if found.is_null() {
                    return Err(format!("the speech engine has no {}", $name));
                }
                // SAFETY: the symbol is the C function of that name, and the field it goes to has the signature parakeet.h (or ggml-backend.h) gives it.
                unsafe { std::mem::transmute::<*mut c_void, _>(found) }
            }};
        }
        // First of all, as no struct has been passed yet: its release.
        let version: unsafe extern "C" fn() -> *const c_char = symbol!("parakeet_version");
        // SAFETY: it takes nothing, and gives a static NUL-terminated string.
        let version = unsafe { version() };
        let version = if version.is_null() {
            String::new()
        } else {
            // SAFETY: as above.
            unsafe { CStr::from_ptr(version) }
                .to_string_lossy()
                .into_owned()
        };
        if !known(&version) {
            return Err(format!(
                "the speech engine ({path}) is whisper.cpp {version:?}, and dictation is made for {VERSION}: it is not used"
            ));
        }
        Ok(Library {
            backend_load_all: symbol!("ggml_backend_load_all"),
            log_set: symbol!("parakeet_log_set"),
            context_default_params: symbol!("parakeet_context_default_params"),
            init_from_file: symbol!("parakeet_init_from_file_with_params"),
            free: symbol!("parakeet_free"),
            full_default_params: symbol!("parakeet_full_default_params"),
            full: symbol!("parakeet_full"),
            n_segments: symbol!("parakeet_full_n_segments"),
            n_tokens: symbol!("parakeet_full_n_tokens"),
            token_data: symbol!("parakeet_full_get_token_data"),
            token_to_str: symbol!("parakeet_token_to_str"),
        })
    }
}

/// A piece of a word as Parakeet heard it, at its times in hundredths of a
/// second from the start of what it was given.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Token {
    /// SentencePiece's piece, with a space where it starts a word ("▁").
    pub text: String,
    pub t0: i64,
    pub t1: i64,
    pub word_start: bool,
}

/// What hears: the engine, or a test's stand-in for it.
pub trait Ear: Send {
    /// What is heard in <samples> (16 kHz mono, -1 to 1), on <threads>
    /// threads; an error as soon as <stop> is set.
    fn hear(
        &mut self,
        samples: &[f32],
        threads: usize,
        stop: &AtomicBool,
    ) -> Result<Vec<Token>, String>;
}

impl Ear for Engine {
    fn hear(
        &mut self,
        samples: &[f32],
        threads: usize,
        stop: &AtomicBool,
    ) -> Result<Vec<Token>, String> {
        Engine::hear(self, samples, threads, stop)
    }
}

/// The model, loaded: about 670 MB of memory, and the compute buffers with it.
pub struct Engine {
    lib: &'static Library,
    ctx: *mut c_void,
}

// The context is used from one thread at a time (the daemon's engine thread
// owns it), which is all whisper.cpp asks.
unsafe impl Send for Engine {}

static OPENED: OnceLock<Result<Library, String>> = OnceLock::new();

/// The library, opened and its CPU backend loaded once a process.
fn library(path: &str) -> Result<&'static Library, String> {
    let opened = OPENED.get_or_init(|| {
        Library::open(path).inspect(|lib| {
            // SAFETY: a valid callback, for the life of the process; then
            // the backends, from the library's own directory.
            unsafe {
                (lib.log_set)(Some(log), std::ptr::null_mut());
                (lib.backend_load_all)();
            }
        })
    });
    opened.as_ref().map_err(Clone::clone)
}

unsafe extern "C" fn stop_asked(data: *mut c_void) -> bool {
    // SAFETY: the data is the &AtomicBool given to hear(), alive for its call.
    unsafe { &*(data as *const AtomicBool) }.load(Ordering::Relaxed)
}

impl Engine {
    /// Loads <model> with the library at <library> (LIBRARY, but for tests),
    /// on the CPU.
    pub fn load(library_path: &str, model: &Path) -> Result<Engine, String> {
        let lib = library(library_path)?;
        let path = CString::new(model.as_os_str().as_encoded_bytes())
            .map_err(|_| "a model path with a NUL".to_owned())?;
        // SAFETY: plain values returned by the library.
        let mut params = unsafe { (lib.context_default_params)() };
        params.use_gpu = false;
        // SAFETY: a NUL-terminated path and the library's own parameters.
        let ctx = unsafe { (lib.init_from_file)(path.as_ptr(), params) };
        if ctx.is_null() {
            return Err(format!(
                "the speech model did not load: {}",
                model.display()
            ));
        }
        Ok(Engine { lib, ctx })
    }

    /// What Parakeet hears in <samples> (16 kHz mono, -1 to 1), on <threads>
    /// threads. Stops, with an error, as soon as <stop> is set.
    pub fn hear(
        &mut self,
        samples: &[f32],
        threads: usize,
        stop: &AtomicBool,
    ) -> Result<Vec<Token>, String> {
        let count = c_int::try_from(samples.len()).map_err(|_| "too long to hear at once")?;
        // SAFETY: plain values returned by the library.
        let mut params = unsafe { (self.lib.full_default_params)(SAMPLING_GREEDY) };
        params.n_threads = threads.clamp(1, 64) as c_int;
        params.no_context = true;
        params.abort_callback = Some(stop_asked);
        params.abort_callback_user_data = stop as *const AtomicBool as *mut c_void;
        // SAFETY: the context is ours; the samples are as many as said; the
        // abort data outlives the call.
        let status = unsafe { (self.lib.full)(self.ctx, params, samples.as_ptr(), count) };
        if stop.load(Ordering::Relaxed) {
            return Err("stopped".into());
        }
        if status != 0 {
            return Err(format!("the speech engine failed ({status})"));
        }
        let mut tokens = Vec::new();
        // SAFETY: the context's results, read before its next use.
        unsafe {
            for segment in 0..(self.lib.n_segments)(self.ctx) {
                for i in 0..(self.lib.n_tokens)(self.ctx, segment) {
                    let data = (self.lib.token_data)(self.ctx, segment, i);
                    let piece = (self.lib.token_to_str)(self.ctx, data.id);
                    if piece.is_null() {
                        continue;
                    }
                    tokens.push(Token {
                        text: CStr::from_ptr(piece).to_string_lossy().into_owned(),
                        t0: data.t0,
                        t1: data.t1,
                        word_start: data.is_word_start,
                    });
                }
            }
        }
        Ok(tokens)
    }

    /// The CPU backend ggml loaded: the libggml-cpu-<generation>.so mapped
    /// into this process.
    pub fn backend() -> Option<String> {
        let maps = std::fs::read_to_string("/proc/self/maps").ok()?;
        maps.lines()
            .filter_map(|line| line.rsplit('/').next())
            .find(|name| name.starts_with("libggml-cpu-") && name.ends_with(".so"))
            .map(str::to_owned)
    }
}

impl Drop for Engine {
    fn drop(&mut self) {
        // SAFETY: the context is ours, freed once.
        unsafe { (self.lib.free)(self.ctx) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_the_release_this_was_written_for_is_known() {
        assert!(known(VERSION));
        assert!(known(&format!("{VERSION}-dev")));
        for other in [
            "1.9.6",
            "1.10.0",
            "1.9.5.1",
            "1.9",
            "",
            "1.9.5-rc1",
            "v1.9.5",
        ] {
            assert!(!known(other), "{other}");
        }
    }

    // The package and the layouts here move together, or the test fails.
    #[test]
    fn the_release_is_the_one_nova_packages() {
        let pkgbuild = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../packaging/whisper-cpp/PKGBUILD"
        );
        let text = std::fs::read_to_string(pkgbuild).unwrap();
        let pkgver = text
            .lines()
            .find_map(|l| l.strip_prefix("pkgver="))
            .expect("a pkgver");
        assert_eq!(pkgver.trim(), VERSION, "{pkgbuild}");
    }
}
