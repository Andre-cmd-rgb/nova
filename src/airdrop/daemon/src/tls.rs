//! TLS, from the system's OpenSSL.
//!
//! AirDrop is HTTPS. Nova's Rust has no crates, and TLS is not something to
//! write for oneself, so it comes from the library every Arch system has. It
//! is looked up when the daemon starts and not when it is built: the daemon
//! then does not hang on one version of the library (libssl.so.3 became
//! libssl.so.4 while this was written), and the few functions used here have
//! been the same through both.
//!
//! A receiver presents a certificate it signed itself. A sender shows a
//! receiver that is not in its contacts whatever certificate it has, so
//! nothing is proven by it either way; it is what makes the link private
//! against the others in range.

use std::ffi::{c_char, c_int, c_long, c_void, CStr, CString};
use std::io::{self, Read, Write};
use std::net::TcpStream;
use std::os::fd::AsRawFd;
use std::path::Path;

extern "C" {
    fn dlopen(name: *const c_char, flags: c_int) -> *mut c_void;
    fn dlsym(handle: *mut c_void, symbol: *const c_char) -> *mut c_void;
}
const RTLD_NOW: c_int = 2;
const RTLD_GLOBAL: c_int = 0x100;

type Ctx = *mut c_void;
type Ssl = *mut c_void;

/// The functions of OpenSSL this uses, as its headers declare them.
struct Library {
    tls_server_method: unsafe extern "C" fn() -> *const c_void,
    ssl_ctx_new: unsafe extern "C" fn(*const c_void) -> Ctx,
    ssl_ctx_free: unsafe extern "C" fn(Ctx),
    ssl_ctx_ctrl: unsafe extern "C" fn(Ctx, c_int, c_long, *mut c_void) -> c_long,
    ssl_ctx_use_certificate_chain_file: unsafe extern "C" fn(Ctx, *const c_char) -> c_int,
    ssl_ctx_use_private_key_file: unsafe extern "C" fn(Ctx, *const c_char, c_int) -> c_int,
    ssl_new: unsafe extern "C" fn(Ctx) -> Ssl,
    ssl_free: unsafe extern "C" fn(Ssl),
    ssl_set_fd: unsafe extern "C" fn(Ssl, c_int) -> c_int,
    ssl_accept: unsafe extern "C" fn(Ssl) -> c_int,
    ssl_read: unsafe extern "C" fn(Ssl, *mut c_void, c_int) -> c_int,
    ssl_write: unsafe extern "C" fn(Ssl, *const c_void, c_int) -> c_int,
    ssl_shutdown: unsafe extern "C" fn(Ssl) -> c_int,
    ssl_get_error: unsafe extern "C" fn(Ssl, c_int) -> c_int,
    err_get_error: unsafe extern "C" fn() -> u64,
    err_error_string_n: unsafe extern "C" fn(u64, *mut c_char, usize),
}

const SSL_CTRL_SET_MIN_PROTO_VERSION: c_int = 123;
const TLS1_2_VERSION: c_long = 0x0303;
const SSL_FILETYPE_PEM: c_int = 1;
const SSL_ERROR_ZERO_RETURN: c_int = 6;

impl Library {
    // Each symbol becomes the type of the field it is put in: the signature is written once, in the structure.
    #[allow(clippy::missing_transmute_annotations)]
    fn load() -> Result<Library, String> {
        let handle = ["libssl.so.4", "libssl.so.3", "libssl.so"]
            .iter()
            .map(|name| {
                let name = CString::new(*name).unwrap();
                // SAFETY: a NUL-terminated name; the library stays loaded for the life of the process.
                unsafe { dlopen(name.as_ptr(), RTLD_NOW | RTLD_GLOBAL) }
            })
            .find(|handle| !handle.is_null())
            .ok_or("no libssl.so.4 or libssl.so.3 on this system")?;
        // A symbol of libssl, or of the libcrypto it brought with it.
        macro_rules! symbol {
            ($name:literal) => {{
                let name = CString::new($name).unwrap();
                // SAFETY: the handle is a loaded library's; the name is NUL-terminated.
                let found = unsafe { dlsym(handle, name.as_ptr()) };
                if found.is_null() {
                    return Err(format!("this system's OpenSSL has no {}", $name));
                }
                // SAFETY: the symbol is the C function of that name, and the field it goes to has the signature OpenSSL's headers give it.
                unsafe { std::mem::transmute::<*mut c_void, _>(found) }
            }};
        }
        Ok(Library {
            tls_server_method: symbol!("TLS_server_method"),
            ssl_ctx_new: symbol!("SSL_CTX_new"),
            ssl_ctx_free: symbol!("SSL_CTX_free"),
            ssl_ctx_ctrl: symbol!("SSL_CTX_ctrl"),
            ssl_ctx_use_certificate_chain_file: symbol!("SSL_CTX_use_certificate_chain_file"),
            ssl_ctx_use_private_key_file: symbol!("SSL_CTX_use_PrivateKey_file"),
            ssl_new: symbol!("SSL_new"),
            ssl_free: symbol!("SSL_free"),
            ssl_set_fd: symbol!("SSL_set_fd"),
            ssl_accept: symbol!("SSL_accept"),
            ssl_read: symbol!("SSL_read"),
            ssl_write: symbol!("SSL_write"),
            ssl_shutdown: symbol!("SSL_shutdown"),
            ssl_get_error: symbol!("SSL_get_error"),
            err_get_error: symbol!("ERR_get_error"),
            err_error_string_n: symbol!("ERR_error_string_n"),
        })
    }

    /// What OpenSSL has to say about the last thing that failed on this thread.
    fn complaint(&self) -> String {
        let mut said = Vec::new();
        loop {
            // SAFETY: no arguments; reads and empties this thread's error queue.
            let code = unsafe { (self.err_get_error)() };
            if code == 0 {
                break;
            }
            let mut text = [0 as c_char; 200];
            // SAFETY: the buffer is as long as it is said to be, and is NUL-terminated by the call.
            unsafe { (self.err_error_string_n)(code, text.as_mut_ptr(), text.len()) };
            // SAFETY: NUL-terminated by the call above.
            said.push(
                unsafe { CStr::from_ptr(text.as_ptr()) }
                    .to_string_lossy()
                    .into_owned(),
            );
        }
        if said.is_empty() {
            "no reason given".into()
        } else {
            said.join("; ")
        }
    }
}

/// This computer as a TLS server: the library and its certificate.
pub struct Server {
    library: Library,
    context: Ctx,
}

// OpenSSL's contexts may be shared between threads; each connection is used by one.
unsafe impl Send for Server {}
unsafe impl Sync for Server {}

impl Server {
    /// With the certificate and key in two PEM files.
    pub fn new(certificate: &Path, key: &Path) -> Result<Server, String> {
        let library = Library::load()?;
        let path = |path: &Path| {
            CString::new(path.to_string_lossy().as_bytes())
                .map_err(|_| "a path with a NUL in it".to_string())
        };
        let (certificate, key) = (path(certificate)?, path(key)?);
        // SAFETY: every call is given what its declaration asks for; the context is checked before it is used and freed if setting it up fails.
        unsafe {
            let context = (library.ssl_ctx_new)((library.tls_server_method)());
            if context.is_null() {
                return Err(format!("OpenSSL would not start: {}", library.complaint()));
            }
            let server = Server { library, context };
            let l = &server.library;
            if (l.ssl_ctx_ctrl)(
                context,
                SSL_CTRL_SET_MIN_PROTO_VERSION,
                TLS1_2_VERSION,
                std::ptr::null_mut(),
            ) != 1
                || (l.ssl_ctx_use_certificate_chain_file)(context, certificate.as_ptr()) != 1
                || (l.ssl_ctx_use_private_key_file)(context, key.as_ptr(), SSL_FILETYPE_PEM) != 1
            {
                return Err(format!("the certificate would not load: {}", l.complaint()));
            }
            Ok(server)
        }
    }

    /// The handshake with a sender that has connected. The stream's own
    /// timeouts bound it, and everything after.
    pub fn accept(&self, stream: TcpStream) -> io::Result<Stream<'_>> {
        let l = &self.library;
        // SAFETY: the context is alive as long as self; the connection is freed by Stream's drop, or here if the handshake fails.
        unsafe {
            let ssl = (l.ssl_new)(self.context);
            if ssl.is_null() {
                return Err(io::Error::other(l.complaint()));
            }
            let connection = Stream {
                server: self,
                ssl,
                stream,
            };
            if (l.ssl_set_fd)(ssl, connection.stream.as_raw_fd()) != 1 || (l.ssl_accept)(ssl) != 1 {
                return Err(io::Error::other(format!(
                    "the handshake failed: {}",
                    l.complaint()
                )));
            }
            Ok(connection)
        }
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        // SAFETY: made by SSL_CTX_new, freed once.
        unsafe { (self.library.ssl_ctx_free)(self.context) };
    }
}

/// A sender's connection, decrypted.
pub struct Stream<'a> {
    server: &'a Server,
    ssl: Ssl,
    // Closed when this is dropped, after the TLS connection is freed.
    stream: TcpStream,
}

unsafe impl Send for Stream<'_> {}

impl Stream<'_> {
    /// The connection under the encryption, for its timeouts and options.
    pub fn socket(&self) -> &TcpStream {
        &self.stream
    }

    fn failed(&self, result: c_int) -> io::Error {
        let l = &self.server.library;
        // SAFETY: the connection is alive and `result` is what the failed call returned.
        match unsafe { (l.ssl_get_error)(self.ssl, result) } {
            // Nothing came or went within the socket's timeout.
            2 | 3 => io::Error::new(io::ErrorKind::TimedOut, "nothing from the sender in time"),
            // The socket itself: its error if it has one, else the sender went away without a word.
            5 => match io::Error::last_os_error() {
                error if error.raw_os_error().unwrap_or(0) != 0 && result < 0 => error,
                _ => io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "the sender closed the connection",
                ),
            },
            _ => io::Error::other(l.complaint()),
        }
    }
}

impl Read for Stream<'_> {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        if buffer.is_empty() {
            return Ok(0);
        }
        let l = &self.server.library;
        // SAFETY: the buffer is as long as the length passed.
        let got = unsafe {
            (l.ssl_read)(
                self.ssl,
                buffer.as_mut_ptr().cast(),
                buffer.len().min(1 << 30) as c_int,
            )
        };
        if got > 0 {
            return Ok(got as usize);
        }
        // SAFETY: as in `failed`.
        if unsafe { (l.ssl_get_error)(self.ssl, got) } == SSL_ERROR_ZERO_RETURN {
            return Ok(0);
        }
        Err(self.failed(got))
    }
}

impl Write for Stream<'_> {
    fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
        if buffer.is_empty() {
            return Ok(0);
        }
        // SAFETY: the buffer is as long as the length passed.
        let sent = unsafe {
            (self.server.library.ssl_write)(
                self.ssl,
                buffer.as_ptr().cast(),
                buffer.len().min(1 << 30) as c_int,
            )
        };
        if sent > 0 {
            Ok(sent as usize)
        } else {
            Err(self.failed(sent))
        }
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

impl Drop for Stream<'_> {
    fn drop(&mut self) {
        // SAFETY: made by SSL_new, freed once, before the socket under it is closed.
        unsafe {
            (self.server.library.ssl_shutdown)(self.ssl);
            (self.server.library.ssl_free)(self.ssl);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;
    use std::process::{Command, Stdio};
    use std::time::Duration;

    /// A certificate as the daemon's is made, in a folder of the test's own.
    fn identity(name: &str) -> (std::path::PathBuf, std::path::PathBuf) {
        let folder =
            std::env::temp_dir().join(format!("nova-airdrop-tls-{}-{name}", std::process::id()));
        std::fs::create_dir_all(&folder).unwrap();
        let (certificate, key) = (folder.join("cert.pem"), folder.join("key.pem"));
        let made = Command::new("openssl")
            .args([
                "req",
                "-x509",
                "-newkey",
                "ec",
                "-pkeyopt",
                "ec_paramgen_curve:prime256v1",
                "-nodes",
                "-days",
                "2",
                "-subj",
                "/CN=nova",
                "-keyout",
            ])
            .arg(&key)
            .arg("-out")
            .arg(&certificate)
            .stderr(Stdio::null())
            .status()
            .unwrap();
        assert!(made.success());
        (certificate, key)
    }

    #[test]
    fn a_client_is_answered_over_tls() {
        let (certificate, key) = identity("answer");
        let server = Server::new(&certificate, &key).unwrap();
        let listener = TcpListener::bind("[::1]:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        // OpenSSL's own client, as any sender: it says a line, and prints what comes back.
        let mut client = Command::new("openssl")
            .args(["s_client", "-quiet", "-connect", &format!("[::1]:{port}")])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let (stream, _) = listener.accept().unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(10)))
            .unwrap();
        let mut tls = server.accept(stream).unwrap();
        client
            .stdin
            .as_mut()
            .unwrap()
            .write_all(b"hello from the sender\n")
            .unwrap();
        let mut heard = [0u8; 64];
        let size = tls.read(&mut heard).unwrap();
        assert_eq!(&heard[..size], b"hello from the sender\n");
        tls.write_all(b"and from the receiver\n").unwrap();
        drop(tls);
        let mut said = String::new();
        client
            .stdout
            .take()
            .unwrap()
            .read_to_string(&mut said)
            .unwrap();
        assert_eq!(said, "and from the receiver\n");
        client.wait().unwrap();
        std::fs::remove_dir_all(certificate.parent().unwrap()).unwrap();
    }

    #[test]
    fn what_is_not_tls_is_turned_away() {
        let (certificate, key) = identity("refuse");
        let server = Server::new(&certificate, &key).unwrap();
        let listener = TcpListener::bind("[::1]:0").unwrap();
        let mut plain = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        plain.write_all(b"GET / HTTP/1.1\r\n\r\n").unwrap();
        let (stream, _) = listener.accept().unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        assert!(server.accept(stream).is_err());
        // One that connects and says nothing: the timeout ends it.
        let _silent = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        let (stream, _) = listener.accept().unwrap();
        stream
            .set_read_timeout(Some(Duration::from_millis(300)))
            .unwrap();
        assert!(server.accept(stream).is_err());
        // No certificate where it was said to be.
        assert!(Server::new(Path::new("/nonexistent/cert.pem"), &key).is_err());
        std::fs::remove_dir_all(certificate.parent().unwrap()).unwrap();
    }
}
