//! gcr's secret exchange, "sx-aes-1": how a password typed on the card
//! reaches gnome-keyring over the session bus without being readable on it.
//!
//! Each side makes a Diffie-Hellman pair in RFC 3526's 1536-bit group (2 as
//! the generator) and sends its public value; the shared value, as unsigned
//! big-endian bytes without leading zeros, goes through HKDF-SHA256 (no salt,
//! no info) to a 16-byte AES key; a secret is sent AES-128-CBC with PKCS#7
//! padding under a fresh 16-byte IV. A message is a key file:
//!
//! ```text
//! [sx-aes-1]
//! public=<base64>
//! secret=<base64>   (with a secret)
//! iv=<base64>       (with a secret)
//! ```
//!
//! The prompter begins (its public value alone); the first public value it
//! receives makes the key, and later ones are not looked at, as gcr does.
//! The arithmetic and the ciphers are libgcrypt's, as gcr's are.

use std::ffi::{c_char, c_int, c_uint, c_ulong, c_void};
use std::ptr;
use std::sync::Once;

const HEADER: &str = "[sx-aes-1]";

/// RFC 3526's 1536-bit MODP group (5), the prime.
const PRIME: [u8; 192] = [
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xC9, 0x0F, 0xDA, 0xA2, 0x21, 0x68, 0xC2, 0x34,
    0xC4, 0xC6, 0x62, 0x8B, 0x80, 0xDC, 0x1C, 0xD1, 0x29, 0x02, 0x4E, 0x08, 0x8A, 0x67, 0xCC, 0x74,
    0x02, 0x0B, 0xBE, 0xA6, 0x3B, 0x13, 0x9B, 0x22, 0x51, 0x4A, 0x08, 0x79, 0x8E, 0x34, 0x04, 0xDD,
    0xEF, 0x95, 0x19, 0xB3, 0xCD, 0x3A, 0x43, 0x1B, 0x30, 0x2B, 0x0A, 0x6D, 0xF2, 0x5F, 0x14, 0x37,
    0x4F, 0xE1, 0x35, 0x6D, 0x6D, 0x51, 0xC2, 0x45, 0xE4, 0x85, 0xB5, 0x76, 0x62, 0x5E, 0x7E, 0xC6,
    0xF4, 0x4C, 0x42, 0xE9, 0xA6, 0x37, 0xED, 0x6B, 0x0B, 0xFF, 0x5C, 0xB6, 0xF4, 0x06, 0xB7, 0xED,
    0xEE, 0x38, 0x6B, 0xFB, 0x5A, 0x89, 0x9F, 0xA5, 0xAE, 0x9F, 0x24, 0x11, 0x7C, 0x4B, 0x1F, 0xE6,
    0x49, 0x28, 0x66, 0x51, 0xEC, 0xE4, 0x5B, 0x3D, 0xC2, 0x00, 0x7C, 0xB8, 0xA1, 0x63, 0xBF, 0x05,
    0x98, 0xDA, 0x48, 0x36, 0x1C, 0x55, 0xD3, 0x9A, 0x69, 0x16, 0x3F, 0xA8, 0xFD, 0x24, 0xCF, 0x5F,
    0x83, 0x65, 0x5D, 0x23, 0xDC, 0xA3, 0xAD, 0x96, 0x1C, 0x62, 0xF3, 0x56, 0x20, 0x85, 0x52, 0xBB,
    0x9E, 0xD5, 0x29, 0x07, 0x70, 0x96, 0x96, 0x6D, 0x67, 0x0C, 0x35, 0x4E, 0x4A, 0xBC, 0x98, 0x04,
    0xF1, 0x74, 0x6C, 0x08, 0xCA, 0x23, 0x73, 0x27, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
];
const PRIME_BITS: c_uint = 1536;

// ---- libgcrypt -------------------------------------------------------------

#[repr(C)]
struct GcryMpi {
    _private: [u8; 0],
}
type RawMpi = *mut GcryMpi;
type Handle = *mut c_void;

const GCRYCTL_DISABLE_SECMEM: c_int = 37;
const GCRYCTL_INITIALIZATION_FINISHED: c_int = 38;
const GCRYMPI_FMT_USG: c_int = 5;
const GCRY_STRONG_RANDOM: c_int = 1;
const GCRY_MD_SHA256: c_int = 8;
const GCRY_MD_FLAG_HMAC: c_uint = 2;
const GCRY_CIPHER_AES128: c_int = 7;
const GCRY_CIPHER_MODE_CBC: c_int = 3;

#[link(name = "gcrypt")]
extern "C" {
    fn gcry_check_version(req: *const c_char) -> *const c_char;
    fn gcry_control(cmd: c_int, ...) -> c_uint;
    fn gcry_mpi_new(nbits: c_uint) -> RawMpi;
    fn gcry_mpi_release(a: RawMpi);
    fn gcry_mpi_scan(
        ret: *mut RawMpi,
        format: c_int,
        buffer: *const c_void,
        buflen: usize,
        nscanned: *mut usize,
    ) -> c_uint;
    fn gcry_mpi_print(
        format: c_int,
        buffer: *mut u8,
        buflen: usize,
        nwritten: *mut usize,
        a: RawMpi,
    ) -> c_uint;
    fn gcry_mpi_powm(w: RawMpi, b: RawMpi, e: RawMpi, m: RawMpi);
    fn gcry_mpi_randomize(w: RawMpi, nbits: c_uint, level: c_int);
    fn gcry_mpi_clear_highbit(a: RawMpi, n: c_uint);
    fn gcry_mpi_cmp_ui(u: RawMpi, v: c_ulong) -> c_int;
    fn gcry_md_open(h: *mut Handle, algo: c_int, flags: c_uint) -> c_uint;
    fn gcry_md_setkey(h: Handle, key: *const c_void, keylen: usize) -> c_uint;
    fn gcry_md_write(h: Handle, buffer: *const c_void, length: usize);
    fn gcry_md_read(h: Handle, algo: c_int) -> *const u8;
    fn gcry_md_close(h: Handle);
    fn gcry_cipher_open(h: *mut Handle, algo: c_int, mode: c_int, flags: c_uint) -> c_uint;
    fn gcry_cipher_setkey(h: Handle, key: *const c_void, keylen: usize) -> c_uint;
    fn gcry_cipher_setiv(h: Handle, iv: *const c_void, ivlen: usize) -> c_uint;
    fn gcry_cipher_encrypt(
        h: Handle,
        out: *mut c_void,
        outsize: usize,
        input: *const c_void,
        inlen: usize,
    ) -> c_uint;
    fn gcry_cipher_decrypt(
        h: Handle,
        out: *mut c_void,
        outsize: usize,
        input: *const c_void,
        inlen: usize,
    ) -> c_uint;
    fn gcry_cipher_close(h: Handle);
    fn gcry_create_nonce(buffer: *mut c_void, length: usize);
}

/// libgcrypt is made ready once, before its first use: no secure memory (a
/// daemon of the user's own, which gcr's prompter does without as well).
fn ready() {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        // SAFETY: the documented start: the version check first, then the controls.
        unsafe {
            gcry_check_version(ptr::null());
            gcry_control(GCRYCTL_DISABLE_SECMEM, 0 as c_int);
            gcry_control(GCRYCTL_INITIALIZATION_FINISHED, 0 as c_int);
        }
    });
}

/// A number of libgcrypt's, released with it.
struct Mpi(RawMpi);

impl Drop for Mpi {
    fn drop(&mut self) {
        // SAFETY: ours, released once.
        unsafe { gcry_mpi_release(self.0) }
    }
}

impl Mpi {
    fn from_bytes(bytes: &[u8]) -> Option<Mpi> {
        let mut raw = ptr::null_mut();
        // SAFETY: a buffer of that length, and a place for the number.
        let r = unsafe {
            gcry_mpi_scan(
                &mut raw,
                GCRYMPI_FMT_USG,
                bytes.as_ptr().cast(),
                bytes.len(),
                ptr::null_mut(),
            )
        };
        (r == 0 && !raw.is_null()).then_some(Mpi(raw))
    }

    /// Unsigned, big-endian, no leading zeros.
    fn to_bytes(&self) -> Vec<u8> {
        let mut length = 0;
        // SAFETY: asks for the length only.
        unsafe { gcry_mpi_print(GCRYMPI_FMT_USG, ptr::null_mut(), 0, &mut length, self.0) };
        let mut out = vec![0; length];
        // SAFETY: a buffer of the length it asked for.
        let r = unsafe {
            gcry_mpi_print(
                GCRYMPI_FMT_USG,
                out.as_mut_ptr(),
                out.len(),
                &mut length,
                self.0,
            )
        };
        out.truncate(if r == 0 { length } else { 0 });
        out
    }

    /// <self>^<exponent> mod <modulus>.
    fn pow_mod(&self, exponent: &Mpi, modulus: &Mpi) -> Mpi {
        // SAFETY: a fresh number for the result, and live ones for the rest.
        unsafe {
            let w = Mpi(gcry_mpi_new(PRIME_BITS));
            gcry_mpi_powm(w.0, self.0, exponent.0, modulus.0);
            w
        }
    }
}

fn hmac_sha256(key: &[u8], data: &[u8]) -> [u8; 32] {
    let mut out = [0; 32];
    let mut h = ptr::null_mut();
    // SAFETY: a handle opened, keyed, fed and read, then closed; the digest
    // is 32 bytes and the handle's until it is closed.
    unsafe {
        if gcry_md_open(&mut h, GCRY_MD_SHA256, GCRY_MD_FLAG_HMAC) != 0 {
            return out;
        }
        if gcry_md_setkey(h, key.as_ptr().cast(), key.len()) == 0 {
            gcry_md_write(h, data.as_ptr().cast(), data.len());
            let digest = gcry_md_read(h, GCRY_MD_SHA256);
            if !digest.is_null() {
                out.copy_from_slice(std::slice::from_raw_parts(digest, 32));
            }
        }
        gcry_md_close(h);
    }
    out
}

/// RFC 5869's HKDF with SHA-256, no salt (32 zeros) and no info, to 16 bytes.
fn hkdf_16(ikm: &[u8]) -> [u8; 16] {
    let mut prk = hmac_sha256(&[0; 32], ikm);
    let mut t1 = hmac_sha256(&prk, &[1]);
    let mut key = [0; 16];
    key.copy_from_slice(&t1[..16]);
    prk.fill(0);
    t1.fill(0);
    key
}

/// AES-128-CBC over <data>, in place; its length a whole number of blocks.
fn aes_cbc(key: &[u8; 16], iv: &[u8; 16], data: &mut [u8], encrypt: bool) -> bool {
    let mut h = ptr::null_mut();
    // SAFETY: a cipher opened, keyed, run in place over the buffer, and closed.
    unsafe {
        if gcry_cipher_open(&mut h, GCRY_CIPHER_AES128, GCRY_CIPHER_MODE_CBC, 0) != 0 {
            return false;
        }
        let ok = gcry_cipher_setkey(h, key.as_ptr().cast(), 16) == 0
            && gcry_cipher_setiv(h, iv.as_ptr().cast(), 16) == 0
            && if encrypt {
                gcry_cipher_encrypt(h, data.as_mut_ptr().cast(), data.len(), ptr::null(), 0) == 0
            } else {
                gcry_cipher_decrypt(h, data.as_mut_ptr().cast(), data.len(), ptr::null(), 0) == 0
            };
        gcry_cipher_close(h);
        ok
    }
}

// ---- base64 ----------------------------------------------------------------

const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

fn base64(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let n = chunk
            .iter()
            .enumerate()
            .fold(0u32, |n, (i, b)| n | (*b as u32) << (16 - 8 * i));
        for i in 0..4 {
            if i <= chunk.len() {
                out.push(ALPHABET[(n >> (18 - 6 * i) & 63) as usize] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

/// Standard base64, padding and white space allowed; none for anything else.
fn unbase64(text: &str) -> Option<Vec<u8>> {
    let mut out = Vec::with_capacity(text.len() / 4 * 3);
    let (mut n, mut bits) = (0u32, 0);
    for c in text.bytes().filter(|c| !c.is_ascii_whitespace()) {
        if c == b'=' {
            break;
        }
        let v = ALPHABET.iter().position(|a| *a == c)? as u32;
        n = n << 6 | v;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((n >> bits) as u8);
            n &= (1 << bits) - 1;
        }
    }
    Some(out)
}

// ---- the exchange ----------------------------------------------------------

/// One side of an exchange: its pair, and the key once the other's public
/// value is in.
pub struct Exchange {
    private: Mpi,
    public: Vec<u8>,
    key: Option<[u8; 16]>,
    /// The secret the other side sent last, as it came (the client's side;
    /// tests use it).
    received: Option<Vec<u8>>,
}

impl Drop for Exchange {
    fn drop(&mut self) {
        if let Some(key) = self.key.as_mut() {
            key.fill(0);
        }
        if let Some(secret) = self.received.as_mut() {
            secret.fill(0);
        }
    }
}

impl Exchange {
    /// A new pair: a private value below 2^1535, as gcr's is, and 2 to its
    /// power.
    pub fn new() -> Exchange {
        ready();
        let prime = Mpi::from_bytes(&PRIME).expect("the group's prime");
        let two = Mpi::from_bytes(&[2]).expect("the generator");
        loop {
            // SAFETY: a fresh number, filled from libgcrypt's strong random pool.
            let private = unsafe {
                let p = Mpi(gcry_mpi_new(PRIME_BITS));
                gcry_mpi_randomize(p.0, PRIME_BITS, GCRY_STRONG_RANDOM);
                gcry_mpi_clear_highbit(p.0, PRIME_BITS - 1);
                p
            };
            // SAFETY: a live number.
            if unsafe { gcry_mpi_cmp_ui(private.0, 1) } <= 0 {
                continue;
            }
            let public = two.pow_mod(&private, &prime).to_bytes();
            return Exchange {
                private,
                public,
                key: None,
                received: None,
            };
        }
    }

    /// The first message: the public value alone.
    pub fn begin(&self) -> String {
        format!("{HEADER}\npublic={}\n", base64(&self.public))
    }

    /// The other side's message. False when it is not one; the key is made
    /// from the first public value, and a secret in it is kept.
    pub fn receive(&mut self, message: &str) -> bool {
        let Some(fields) = fields(message) else {
            return false;
        };
        let get = |key: &str| fields.iter().find(|(k, _)| *k == key).map(|(_, v)| *v);
        let Some(public) = get("public").and_then(unbase64).filter(|p| !p.is_empty()) else {
            return false;
        };
        if self.key.is_none() {
            let (Some(theirs), Some(prime)) = (Mpi::from_bytes(&public), Mpi::from_bytes(&PRIME))
            else {
                return false;
            };
            let mut shared = theirs.pow_mod(&self.private, &prime).to_bytes();
            self.key = Some(hkdf_16(&shared));
            shared.fill(0);
        }
        if let (Some(secret), Some(iv)) = (get("secret"), get("iv")) {
            let (Some(mut secret), Some(iv)) = (unbase64(secret), unbase64(iv)) else {
                return false;
            };
            let key = self.key.expect("made above");
            let Ok(iv) = <[u8; 16]>::try_from(iv.as_slice()) else {
                return false;
            };
            if secret.is_empty()
                || secret.len() % 16 != 0
                || !aes_cbc(&key, &iv, &mut secret, false)
            {
                return false;
            }
            let pad = *secret.last().expect("not empty") as usize;
            if pad == 0
                || pad > 16
                || secret[secret.len() - pad..]
                    .iter()
                    .any(|b| *b as usize != pad)
            {
                secret.fill(0);
                return false;
            }
            secret.truncate(secret.len() - pad);
            if let Some(old) = self.received.as_mut() {
                old.fill(0);
            }
            self.received = Some(secret);
        }
        true
    }

    /// A message with this side's public value and, with <secret>, the secret
    /// under the key; none before the other side's public value is in.
    pub fn send(&self, secret: Option<&[u8]>) -> Option<String> {
        let mut message = self.begin();
        let Some(secret) = secret else {
            return self.key.is_some().then_some(message);
        };
        let key = self.key?;
        let mut iv = [0u8; 16];
        // SAFETY: a buffer of that length.
        unsafe { gcry_create_nonce(iv.as_mut_ptr().cast(), iv.len()) };
        let pad = 16 - secret.len() % 16;
        let mut data = Vec::with_capacity(secret.len() + pad);
        data.extend_from_slice(secret);
        data.resize(secret.len() + pad, pad as u8);
        if !aes_cbc(&key, &iv, &mut data, true) {
            data.fill(0);
            return None;
        }
        message.push_str(&format!("secret={}\niv={}\n", base64(&data), base64(&iv)));
        Some(message)
    }

    #[cfg(test)]
    pub fn received(&self) -> Option<&[u8]> {
        self.received.as_deref()
    }
}

/// A message's keys and values, in its [sx-aes-1] group; none when it has
/// no such group first.
fn fields(message: &str) -> Option<Vec<(&str, &str)>> {
    let mut lines = message
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with('#'));
    if lines.next()? != HEADER {
        return None;
    }
    Some(
        lines
            .take_while(|l| !l.starts_with('['))
            .filter_map(|l| l.split_once('='))
            .map(|(k, v)| (k.trim(), v.trim()))
            .collect(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base64_is_the_standard_one() {
        for (bytes, text) in [
            (&b""[..], ""),
            (b"f", "Zg=="),
            (b"fo", "Zm8="),
            (b"foo", "Zm9v"),
            (b"foob", "Zm9vYg=="),
            (b"\xff\x00\xfe", "/wD+"),
        ] {
            assert_eq!(base64(bytes), text);
            assert_eq!(unbase64(text).unwrap(), bytes);
        }
        assert_eq!(unbase64("Zm9v\nYg==").unwrap(), b"foob");
        assert!(unbase64("Zm9v!").is_none());
    }

    #[test]
    fn hkdf_and_hmac_are_rfc_5869s() {
        // RFC 4231 test case 2: HMAC-SHA256 with key "Jefe".
        assert_eq!(
            hex(&hmac_sha256(b"Jefe", b"what do ya want for nothing?")),
            "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
        );
        // RFC 5869 test case 3 (no salt, no info), its first 16 bytes.
        assert_eq!(
            hex(&hkdf_16(&[0x0b; 22])),
            "8da4e775a563c18f715f802a063c5a31"
        );
    }

    fn hex(bytes: &[u8]) -> String {
        bytes.iter().map(|b| format!("{b:02x}")).collect()
    }

    #[test]
    fn two_sides_agree_and_a_secret_crosses() {
        let mut prompter = Exchange::new();
        let mut client = Exchange::new();
        // Nothing to send under before the other's public value.
        assert!(prompter.send(Some(b"x")).is_none());
        assert!(client.receive(&prompter.begin()));
        assert!(prompter.receive(&client.send(None).unwrap()));
        for secret in [
            &b"correct horse"[..],
            b"",
            b"0123456789abcdef",
            "pässwörd".as_bytes(),
        ] {
            let message = prompter.send(Some(secret)).unwrap();
            assert!(message.starts_with("[sx-aes-1]\npublic="));
            assert!(message.contains("\nsecret=") && message.contains("\niv="));
            assert!(client.receive(&message));
            assert_eq!(client.received().unwrap(), secret);
        }
        // A later public value does not change the key.
        let other = Exchange::new();
        assert!(prompter.receive(&other.begin()));
        assert!(client.receive(&prompter.send(Some(b"still")).unwrap()));
        assert_eq!(client.received().unwrap(), b"still");
    }

    #[test]
    fn what_is_not_a_message_is_refused() {
        let mut side = Exchange::new();
        assert!(!side.receive(""));
        assert!(!side.receive("[other]\npublic=AA==\n"));
        assert!(!side.receive("[sx-aes-1]\n"));
        assert!(!side.receive("[sx-aes-1]\npublic=!!\n"));
        let peer = Exchange::new();
        assert!(side.receive(&peer.begin()));
        assert!(!side.receive(&format!("{}secret=AAAA\niv=AAAA\n", peer.begin())));
    }
}
