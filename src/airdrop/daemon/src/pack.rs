//! What this computer uploads when it sends: its files as one cpio archive,
//! in the old all-octal headers AirDrop's own archives have, packed as one
//! gzip stream. It is made as it goes out, a piece at a time, so a film of
//! some gigabytes needs no more memory than a photo.
//!
//! The headers say "./name", as the paths the question gave (FileBomPath),
//! under an entry for "." itself, as an iPhone's archives have.

use std::ffi::{c_char, c_int};
use std::fs::File;
use std::io::{self, Read};

use crate::unpack::ZStream;

#[link(name = "z")]
extern "C" {
    fn zlibVersion() -> *const c_char;
    fn deflateInit2_(
        stream: *mut ZStream,
        level: c_int,
        method: c_int,
        window_bits: c_int,
        memory_level: c_int,
        strategy: c_int,
        version: *const c_char,
        stream_size: c_int,
    ) -> c_int;
    fn deflate(stream: *mut ZStream, flush: c_int) -> c_int;
    fn deflateEnd(stream: *mut ZStream) -> c_int;
}

const Z_OK: c_int = 0;
const Z_STREAM_END: c_int = 1;
const Z_BUF_ERROR: c_int = -5;
const Z_FINISH: c_int = 4;
const Z_DEFLATED: c_int = 8;
/// gzip's wrapping, and zlib's largest window.
const GZIP: c_int = 31;
/// Photos and films do not shrink, and the air is slower than any level: the quickest.
const LEVEL: c_int = 1;

/// The largest file the headers can say the size of: eleven octal digits.
pub const LARGEST: u64 = 0o77_777_777_777;
/// How much of the files goes into one piece.
const PIECE: usize = 256 << 10;

struct Deflate {
    // Boxed: zlib keeps a pointer to the stream inside its own state.
    stream: Box<ZStream>,
}

// The stream is owned and used by one thread at a time.
unsafe impl Send for Deflate {}

impl Deflate {
    fn new() -> io::Result<Deflate> {
        // SAFETY: an all-zero stream is what zlib asks to be given, and the size passed is the size of the structure it is given.
        unsafe {
            let mut stream: Box<ZStream> = Box::new(std::mem::zeroed());
            if deflateInit2_(
                &mut *stream,
                LEVEL,
                Z_DEFLATED,
                GZIP,
                8,
                0,
                zlibVersion(),
                std::mem::size_of::<ZStream>() as c_int,
            ) != Z_OK
            {
                return Err(io::Error::other("zlib would not start"));
            }
            Ok(Deflate { stream })
        }
    }

    /// Packs `input` onto the end of `out`; with `last`, and the end of the stream.
    fn feed(&mut self, input: &[u8], out: &mut Vec<u8>, last: bool) -> io::Result<()> {
        let mut room = [0u8; 65536];
        self.stream.next_in = input.as_ptr();
        self.stream.avail_in = input.len() as u32;
        loop {
            self.stream.next_out = room.as_mut_ptr();
            self.stream.avail_out = room.len() as u32;
            // SAFETY: the pointers and lengths set describe `input` and `room`, both alive across the call.
            let status = unsafe { deflate(&mut *self.stream, if last { Z_FINISH } else { 0 }) };
            let made = room.len() - self.stream.avail_out as usize;
            out.extend_from_slice(&room[..made]);
            match status {
                Z_STREAM_END => return Ok(()),
                Z_BUF_ERROR if made == 0 && last => {
                    return Err(io::Error::other("zlib would not finish"))
                }
                Z_OK | Z_BUF_ERROR => {
                    // All taken in, and nothing more coming out until there is more.
                    if self.stream.avail_in == 0 && self.stream.avail_out != 0 && !last {
                        return Ok(());
                    }
                }
                _ => return Err(io::Error::other("zlib would not pack")),
            }
        }
    }
}

impl Drop for Deflate {
    fn drop(&mut self) {
        // SAFETY: the stream was set up by deflateInit2_; this is the one place it is ended.
        unsafe { deflateEnd(&mut *self.stream) };
    }
}

/// A file to send: the name it goes under, the file, its size and when it was last changed (Unix
/// seconds).
pub struct Item {
    pub name: String,
    pub file: File,
    pub size: u64,
    pub modified: u64,
}

/// A header of the old cpio format, all octal, and its name after it.
fn header(number: u32, mode: u32, modified: u64, name: &str, size: u64) -> Vec<u8> {
    let mut out = format!(
        "070707{:06o}{:06o}{:06o}{:06o}{:06o}{:06o}{:06o}{:011o}{:06o}{:011o}",
        0,
        number & 0o777_777,
        mode,
        501,
        20,
        1,
        0,
        modified.min(LARGEST),
        name.len() + 1,
        size
    )
    .into_bytes();
    out.extend_from_slice(name.as_bytes());
    out.push(0);
    out
}

/// The names the files go under: their own, and a second of one name with a number, as a
/// receiver would make it, since the archive has room for one of each.
pub fn names(wanted: &[String]) -> Vec<String> {
    let mut given: Vec<String> = Vec::with_capacity(wanted.len());
    for name in wanted {
        let name = if name.is_empty() || name == "." || name == ".." {
            "file".to_owned()
        } else {
            name.clone()
        };
        let (stem, extension) = match name.rfind('.') {
            Some(dot) if dot > 0 => (&name[..dot], &name[dot..]),
            _ => (name.as_str(), ""),
        };
        let mut candidate = name.clone();
        let mut number = 2;
        while given.contains(&candidate) {
            candidate = format!("{stem} {number}{extension}");
            number += 1;
        }
        given.push(candidate);
    }
    given
}

/// The upload, made a piece at a time.
pub struct Pack {
    items: Vec<Item>,
    /// The next file whose header goes out; past the last, the trailer.
    next: usize,
    /// The file being read and how much of it is still to come.
    reading: Option<(usize, u64)>,
    deflate: Deflate,
    started: bool,
    finished: bool,
    /// Bytes of the files read so far.
    pub read: u64,
    pub bytes: u64,
}

impl Pack {
    pub fn new(items: Vec<Item>) -> io::Result<Pack> {
        if let Some(item) = items.iter().find(|item| item.size > LARGEST) {
            return Err(io::Error::other(format!(
                "{} is larger than AirDrop can take in one piece (8 GB)",
                item.name
            )));
        }
        Ok(Pack {
            bytes: items.iter().map(|item| item.size).sum(),
            items,
            next: 0,
            reading: None,
            deflate: Deflate::new()?,
            started: false,
            finished: false,
            read: 0,
        })
    }

    /// The next piece of the upload, packed; None once it has all gone.
    pub fn piece(&mut self) -> io::Result<Option<Vec<u8>>> {
        let mut out = Vec::new();
        while out.is_empty() {
            if self.finished {
                return Ok(None);
            }
            let mut plain = Vec::with_capacity(PIECE + 512);
            if !self.started {
                self.started = true;
                plain.extend_from_slice(&header(0, 0o040755, 0, ".", 0));
            }
            while plain.len() < PIECE {
                if let Some((index, left)) = self.reading {
                    let item = &mut self.items[index];
                    let take = (PIECE - plain.len()).min(left.min(usize::MAX as u64) as usize);
                    let at = plain.len();
                    plain.resize(at + take, 0);
                    let mut filled = 0;
                    while filled < take {
                        match item.file.read(&mut plain[at + filled..]) {
                            Ok(0) => {
                                return Err(io::Error::other(format!(
                                    "{} became shorter while it was being sent",
                                    item.name
                                )))
                            }
                            Ok(size) => filled += size,
                            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
                            Err(error) => return Err(error),
                        }
                    }
                    self.read += take as u64;
                    let left = left - take as u64;
                    self.reading = (left > 0).then_some((index, left));
                } else if self.next < self.items.len() {
                    let item = &self.items[self.next];
                    plain.extend_from_slice(&header(
                        self.next as u32 + 1,
                        0o100644,
                        item.modified,
                        &format!("./{}", item.name),
                        item.size,
                    ));
                    if item.size > 0 {
                        self.reading = Some((self.next, item.size));
                    }
                    self.next += 1;
                } else {
                    plain.extend_from_slice(&header(0, 0, 0, "TRAILER!!!", 0));
                    self.finished = true;
                    break;
                }
            }
            self.deflate.feed(&plain, &mut out, self.finished)?;
        }
        Ok(Some(out))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::unpack::{Archive, Landing, Packing};

    fn scratch(name: &str) -> std::path::PathBuf {
        let folder =
            std::env::temp_dir().join(format!("nova-airdrop-pack-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&folder);
        std::fs::create_dir_all(&folder).unwrap();
        folder
    }

    fn item(folder: &std::path::Path, name: &str, data: &[u8]) -> Item {
        let path = folder.join(format!("source-{name}"));
        std::fs::write(&path, data).unwrap();
        Item {
            name: name.into(),
            file: File::open(&path).unwrap(),
            size: data.len() as u64,
            modified: 1_700_000_000,
        }
    }

    /// Something no packer can shrink, of this size.
    fn photo(size: usize) -> Vec<u8> {
        let mut state = 0x9e37_79b9_7f4a_7c15u64;
        (0..size)
            .map(|_| {
                state ^= state << 13;
                state ^= state >> 7;
                state ^= state << 17;
                state as u8
            })
            .collect()
    }

    #[test]
    fn what_is_packed_here_is_unpacked_by_the_receiving_side() {
        let folder = scratch("round");
        let big = photo(700_000);
        let items = vec![
            item(&folder, "IMG_0001.JPG", &big),
            item(&folder, "notes.txt", b"three lines\nof text\nhere\n"),
            item(&folder, "empty", b""),
        ];
        let mut pack = Pack::new(items).unwrap();
        assert_eq!(pack.bytes, 700_000 + 25);
        let mut upload = Vec::new();
        let mut pieces = 0;
        while let Some(piece) = pack.piece().unwrap() {
            assert!(!piece.is_empty());
            upload.extend_from_slice(&piece);
            pieces += 1;
        }
        assert!(pieces >= 2, "a piece at a time");
        assert_eq!(pack.read, pack.bytes);
        assert_eq!(&upload[..2], &[0x1f, 0x8b], "gzip");

        // Through the receiver's own unpacking, as Nova receives from Nova.
        let into = folder.join("in");
        let landing = Landing::new(&into).unwrap();
        let mut archive = Archive::new(&landing, pack.bytes);
        let mut packing = Packing::of("application/x-cpio").unwrap();
        for piece in upload.chunks(1000) {
            packing
                .feed(piece, &mut |plain| archive.feed(plain))
                .unwrap();
        }
        assert!(archive.done());
        assert_eq!((archive.files, archive.skipped.len()), (3, 0));
        drop(archive);
        let mut kept = landing.keep().unwrap();
        kept.sort();
        assert_eq!(
            kept,
            vec![
                into.join("IMG_0001.JPG"),
                into.join("empty"),
                into.join("notes.txt")
            ]
        );
        assert_eq!(std::fs::read(into.join("IMG_0001.JPG")).unwrap(), big);
        assert_eq!(
            std::fs::read(into.join("notes.txt")).unwrap(),
            b"three lines\nof text\nhere\n"
        );
        std::fs::remove_dir_all(&folder).unwrap();
    }

    #[test]
    fn a_file_that_shrinks_on_the_way_is_an_error_and_a_huge_one_is_refused() {
        let folder = scratch("short");
        let mut short = item(&folder, "a.jpg", b"0123456789");
        short.size = 20;
        let mut pack = Pack::new(vec![short]).unwrap();
        let mut failed = None;
        loop {
            match pack.piece() {
                Ok(Some(_)) => {}
                Ok(None) => break,
                Err(error) => {
                    failed = Some(error.to_string());
                    break;
                }
            }
        }
        assert_eq!(
            failed.as_deref(),
            Some("a.jpg became shorter while it was being sent")
        );
        let mut huge = item(&folder, "film.mov", b"");
        huge.size = LARGEST + 1;
        assert!(Pack::new(vec![huge]).is_err());
        std::fs::remove_dir_all(&folder).unwrap();
    }

    #[test]
    fn two_files_of_one_name_go_under_two() {
        let wanted: Vec<String> = [
            "IMG_1.JPG",
            "IMG_1.JPG",
            "notes",
            "notes",
            "IMG_1.JPG",
            ".",
            "",
        ]
        .iter()
        .map(|name| name.to_string())
        .collect();
        assert_eq!(
            names(&wanted),
            [
                "IMG_1.JPG",
                "IMG_1 2.JPG",
                "notes",
                "notes 2",
                "IMG_1 3.JPG",
                "file",
                "file 2"
            ]
        );
    }

    #[test]
    fn a_header_is_what_the_receiving_side_reads() {
        let made = header(3, 0o100644, 0o17, "./a", 70_000);
        assert_eq!(made.len(), 76 + 4);
        assert_eq!(&made[..6], b"070707");
        assert_eq!(&made[59..65], b"000004", "the name's length, its NUL in it");
        assert_eq!(&made[65..76], b"00000210560", "the size");
        assert_eq!(&made[76..], b"./a\0");
    }
}
