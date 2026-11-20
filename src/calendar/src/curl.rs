//! libcurl's easy interface, as much of it as the sync asks: one handle,
//! its connections kept open between requests, each request made whole
//! (method, headers, body) and its answer read into memory up to a limit.

use std::ffi::{c_char, c_int, c_long, c_void, CString};
use std::ptr;
use std::sync::Once;
use std::time::Duration;

#[repr(C)]
struct CurlHandle {
    _private: [u8; 0],
}

#[repr(C)]
struct Slist {
    data: *mut c_char,
    next: *mut Slist,
}

type WriteFn = extern "C" fn(*const c_char, usize, usize, *mut c_void) -> usize;

const CURL_GLOBAL_DEFAULT: c_long = 3;
const OPT_WRITEDATA: c_int = 10001;
const OPT_URL: c_int = 10002;
const OPT_WRITEFUNCTION: c_int = 20011;
const OPT_POSTFIELDS: c_int = 10015;
const OPT_LOW_SPEED_LIMIT: c_int = 19;
const OPT_LOW_SPEED_TIME: c_int = 20;
const OPT_HTTPHEADER: c_int = 10023;
const OPT_HEADERDATA: c_int = 10029;
const OPT_CUSTOMREQUEST: c_int = 10036;
const OPT_FOLLOWLOCATION: c_int = 52;
const OPT_HEADERFUNCTION: c_int = 20079;
const OPT_HTTPGET: c_int = 80;
const OPT_NOSIGNAL: c_int = 99;
const OPT_POSTFIELDSIZE_LARGE: c_int = 30120;
const OPT_TIMEOUT_MS: c_int = 155;
const OPT_CONNECTTIMEOUT_MS: c_int = 156;
const OPT_PATH_AS_IS: c_int = 234;
const OPT_PROTOCOLS_STR: c_int = 10318;
const INFO_RESPONSE_CODE: c_int = 0x200000 + 2;

pub const E_OPERATION_TIMEDOUT: c_int = 28;
pub const E_PEER_FAILED_VERIFICATION: c_int = 60;
pub const E_GOT_NOTHING: c_int = 52;
pub const E_SEND_ERROR: c_int = 55;
pub const E_RECV_ERROR: c_int = 56;

#[link(name = "curl")]
extern "C" {
    fn curl_global_init(flags: c_long) -> c_int;
    fn curl_easy_init() -> *mut CurlHandle;
    fn curl_easy_cleanup(h: *mut CurlHandle);
    fn curl_easy_reset(h: *mut CurlHandle);
    fn curl_easy_setopt(h: *mut CurlHandle, option: c_int, ...) -> c_int;
    fn curl_easy_perform(h: *mut CurlHandle) -> c_int;
    fn curl_easy_getinfo(h: *mut CurlHandle, info: c_int, ...) -> c_int;
    fn curl_slist_append(list: *mut Slist, s: *const c_char) -> *mut Slist;
    fn curl_slist_free_all(list: *mut Slist);
}

/// What came back: the status, the headers (names lower-cased, the last of
/// a name twice), and the body.
pub struct Answer {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

/// Why a request failed: libcurl's code, and whether the body went past
/// the limit.
#[derive(Debug)]
pub struct Failed {
    pub code: c_int,
    pub too_big: bool,
}

struct Sink {
    body: Vec<u8>,
    limit: usize,
    too_big: bool,
    headers: Vec<(String, String)>,
}

extern "C" fn on_body(data: *const c_char, size: usize, n: usize, user: *mut c_void) -> usize {
    // SAFETY: <user> is the Sink perform() handed libcurl, alive for the
    // call; <data> is <size * n> bytes of libcurl's.
    let sink = unsafe { &mut *(user as *mut Sink) };
    let len = size * n;
    if sink.body.len() + len > sink.limit {
        sink.too_big = true;
        return 0;
    }
    sink.body
        .extend_from_slice(unsafe { std::slice::from_raw_parts(data as *const u8, len) });
    len
}

extern "C" fn on_header(data: *const c_char, size: usize, n: usize, user: *mut c_void) -> usize {
    // SAFETY: as on_body.
    let sink = unsafe { &mut *(user as *mut Sink) };
    let len = size * n;
    let line =
        String::from_utf8_lossy(unsafe { std::slice::from_raw_parts(data as *const u8, len) })
            .into_owned();
    let line = line.trim_end_matches(['\r', '\n']);
    if line.starts_with("HTTP/") {
        // A new answer (after a 100 Continue, or a proxy's): its own headers.
        sink.headers.clear();
    } else if let Some((name, value)) = line.split_once(':') {
        let name = name.trim().to_ascii_lowercase();
        let value = value.trim().to_string();
        match sink.headers.iter_mut().find(|(k, _)| *k == name) {
            Some((_, v)) => *v = value,
            None => sink.headers.push((name, value)),
        }
    }
    len
}

pub struct Easy {
    h: *mut CurlHandle,
}

impl Drop for Easy {
    fn drop(&mut self) {
        // SAFETY: ours, cleaned up once.
        unsafe { curl_easy_cleanup(self.h) }
    }
}

struct Headers(*mut Slist);

impl Drop for Headers {
    fn drop(&mut self) {
        // SAFETY: a list libcurl made, freed once, after the request.
        unsafe { curl_slist_free_all(self.0) }
    }
}

impl Easy {
    pub fn new() -> Option<Easy> {
        static ONCE: Once = Once::new();
        // SAFETY: the documented start, once, before any handle.
        ONCE.call_once(|| unsafe {
            curl_global_init(CURL_GLOBAL_DEFAULT);
        });
        // SAFETY: a new handle, ours until dropped.
        let h = unsafe { curl_easy_init() };
        (!h.is_null()).then_some(Easy { h })
    }

    /// One request. <timeout>: the whole of it; <idle>: the longest with no
    /// byte moving (and to connect).
    #[allow(clippy::too_many_arguments)]
    pub fn perform(
        &mut self,
        method: &str,
        url: &str,
        headers: &[(String, String)],
        body: Option<&[u8]>,
        timeout: Duration,
        idle: Duration,
        limit: usize,
    ) -> Result<Answer, Failed> {
        let failed = |code: c_int| Failed {
            code,
            too_big: false,
        };
        let c_url = CString::new(url).map_err(|_| failed(3))?;
        let c_method = CString::new(method).map_err(|_| failed(3))?;
        let mut list = Headers(ptr::null_mut());
        let mut lines: Vec<String> = headers.iter().map(|(k, v)| format!("{k}: {v}")).collect();
        // No "Expect: 100-continue" wait before a large body.
        lines.push("Expect:".into());
        if body.is_none() {
            lines.push("Content-Type:".into());
        }
        for line in &lines {
            let c = CString::new(line.as_str()).map_err(|_| failed(43))?;
            // SAFETY: libcurl copies the string into the list.
            let next = unsafe { curl_slist_append(list.0, c.as_ptr()) };
            if next.is_null() {
                return Err(failed(27));
            }
            list.0 = next;
        }
        let mut sink = Sink {
            body: Vec::new(),
            limit,
            too_big: false,
            headers: Vec::new(),
        };
        let protocols = c"http,https";
        let mut status: c_long = 0;
        let ms = |d: Duration| d.as_millis().clamp(1, c_long::MAX as u128) as c_long;
        // SAFETY: every option of the type libcurl documents for it; the
        // strings, the list, and the sink outlive the
        // perform call below, after which the handle is reset.
        let code = unsafe {
            let h = self.h;
            curl_easy_reset(h);
            curl_easy_setopt(h, OPT_URL, c_url.as_ptr());
            curl_easy_setopt(h, OPT_PROTOCOLS_STR, protocols.as_ptr());
            curl_easy_setopt(h, OPT_PATH_AS_IS, 1 as c_long);
            curl_easy_setopt(h, OPT_FOLLOWLOCATION, 0 as c_long);
            curl_easy_setopt(h, OPT_NOSIGNAL, 1 as c_long);
            curl_easy_setopt(h, OPT_TIMEOUT_MS, ms(timeout));
            curl_easy_setopt(h, OPT_CONNECTTIMEOUT_MS, ms(idle));
            curl_easy_setopt(h, OPT_LOW_SPEED_LIMIT, 1 as c_long);
            curl_easy_setopt(h, OPT_LOW_SPEED_TIME, idle.as_secs().max(1) as c_long);
            curl_easy_setopt(h, OPT_HTTPHEADER, list.0);
            curl_easy_setopt(h, OPT_WRITEFUNCTION, on_body as WriteFn);
            curl_easy_setopt(h, OPT_WRITEDATA, &mut sink as *mut Sink as *mut c_void);
            curl_easy_setopt(h, OPT_HEADERFUNCTION, on_header as WriteFn);
            curl_easy_setopt(h, OPT_HEADERDATA, &mut sink as *mut Sink as *mut c_void);
            match body {
                Some(b) => {
                    curl_easy_setopt(h, OPT_POSTFIELDSIZE_LARGE, b.len() as i64);
                    curl_easy_setopt(h, OPT_POSTFIELDS, b.as_ptr() as *const c_char);
                }
                None => {
                    curl_easy_setopt(h, OPT_HTTPGET, 1 as c_long);
                }
            }
            if method != "GET" || body.is_some() {
                curl_easy_setopt(h, OPT_CUSTOMREQUEST, c_method.as_ptr());
            }
            let code = curl_easy_perform(h);
            if code == 0 {
                curl_easy_getinfo(h, INFO_RESPONSE_CODE, &mut status as *mut c_long);
            }
            // Nothing of this call left in the handle: no pointer to what is
            // about to go.
            curl_easy_reset(h);
            code
        };
        if code != 0 {
            return Err(Failed {
                code,
                too_big: sink.too_big,
            });
        }
        Ok(Answer {
            status: status.clamp(0, 999) as u16,
            headers: sink.headers,
            body: sink.body,
        })
    }
}
