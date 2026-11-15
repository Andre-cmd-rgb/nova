//! What a sender uploads, unpacked as it arrives.
//!
//! An upload is a cpio archive, packed one of two ways: as one gzip stream
//! (what the protocol's public descriptions say a receiver without Apple's
//! format gets) or as DVZip (what an iPhone sent anyway). Both are read here
//! piece by piece, so a film of some gigabytes needs no more memory than a
//! photo, and into a folder of its own inside the folder files are received
//! in: nothing is seen there until all of it has arrived, and nothing is left
//! there if it does not.
//!
//! The archive comes from whoever is in range, so its names are not trusted
//! (no path leaves the folder, nothing but files and folders is made), nor
//! its sizes (no more is written than the sender said it would send).

use std::ffi::{c_char, c_int, c_void, CString};
use std::fs::{self, File};
use std::io::{self, Write};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

#[derive(Debug)]
pub enum Error {
    /// The upload is not what it should be: said in the log, and to the sender as a failure.
    Bad(&'static str),
    /// More than was announced.
    TooMuch,
    Io(io::Error),
}

impl From<io::Error> for Error {
    fn from(error: io::Error) -> Self {
        Error::Io(error)
    }
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        match self {
            Error::Bad(what) => write!(f, "{what}"),
            Error::TooMuch => write!(f, "more arrived than was announced"),
            Error::Io(error) => write!(f, "{error}"),
        }
    }
}

// ------------------------------------------------------------------- inflate

// zlib's stream, as its header lays it out for 64-bit Linux, and the four
// functions inflating needs. libz.so.1 has had this shape since the nineties.
#[repr(C)]
struct ZStream {
    next_in: *const u8,
    avail_in: u32,
    total_in: u64,
    next_out: *mut u8,
    avail_out: u32,
    total_out: u64,
    msg: *const c_char,
    state: *mut c_void,
    zalloc: *const c_void,
    zfree: *const c_void,
    opaque: *mut c_void,
    data_type: c_int,
    adler: u64,
    reserved: u64,
}

#[link(name = "z")]
extern "C" {
    fn zlibVersion() -> *const c_char;
    fn inflateInit2_(
        stream: *mut ZStream,
        window_bits: c_int,
        version: *const c_char,
        stream_size: c_int,
    ) -> c_int;
    fn inflate(stream: *mut ZStream, flush: c_int) -> c_int;
    fn inflateReset(stream: *mut ZStream) -> c_int;
    fn inflateEnd(stream: *mut ZStream) -> c_int;
}

const Z_OK: c_int = 0;
const Z_STREAM_END: c_int = 1;
const Z_BUF_ERROR: c_int = -5;

struct Inflate {
    // Boxed: zlib keeps a pointer to the stream inside its own state.
    stream: Box<ZStream>,
    ended: bool,
}

// The stream is owned and used by one thread at a time.
unsafe impl Send for Inflate {}

impl Inflate {
    /// `window_bits`: 15 for a zlib stream, 31 for gzip.
    fn new(window_bits: c_int) -> Result<Inflate, Error> {
        // SAFETY: an all-zero stream is what zlib asks to be given, and the size passed is the size of the structure it is given.
        unsafe {
            let mut stream: Box<ZStream> = Box::new(std::mem::zeroed());
            if inflateInit2_(
                &mut *stream,
                window_bits,
                zlibVersion(),
                std::mem::size_of::<ZStream>() as c_int,
            ) != Z_OK
            {
                return Err(Error::Bad("zlib would not start"));
            }
            Ok(Inflate {
                stream,
                ended: false,
            })
        }
    }

    /// Unpacks what it is given into `sink`; says how many bytes of the input it used (all of them, unless the stream ended inside).
    fn feed(
        &mut self,
        mut input: &[u8],
        sink: &mut dyn FnMut(&[u8]) -> Result<(), Error>,
    ) -> Result<usize, Error> {
        let given = input.len();
        let mut out = [0u8; 65536];
        while !input.is_empty() && !self.ended {
            self.stream.next_in = input.as_ptr();
            self.stream.avail_in = input.len().min(1 << 30) as u32;
            self.stream.next_out = out.as_mut_ptr();
            self.stream.avail_out = out.len() as u32;
            let offered = self.stream.avail_in;
            // SAFETY: the pointers and lengths just set describe `input` and `out`, both alive across the call.
            let status = unsafe { inflate(&mut *self.stream, 0) };
            input = &input[(offered - self.stream.avail_in) as usize..];
            let made = out.len() - self.stream.avail_out as usize;
            if made > 0 {
                sink(&out[..made])?;
            }
            match status {
                Z_OK => {}
                Z_STREAM_END => self.ended = true,
                // No progress possible: not an error unless it also made nothing with input left.
                Z_BUF_ERROR if made > 0 || input.is_empty() => {}
                _ => return Err(Error::Bad("the upload is not packed as it says")),
            }
        }
        Ok(given - input.len())
    }

    fn again(&mut self) {
        // SAFETY: the stream was set up by inflateInit2_ and is not in use.
        unsafe { inflateReset(&mut *self.stream) };
        self.ended = false;
    }
}

impl Drop for Inflate {
    fn drop(&mut self) {
        // SAFETY: the stream was set up by inflateInit2_; this is the one place it is ended.
        unsafe { inflateEnd(&mut *self.stream) };
    }
}

/// How an upload is packed.
pub struct Packing(Kind);

enum Kind {
    Gzip(Inflate),
    /// Pieces: a length of four bytes (big endian) and that many bytes, a
    /// zlib stream of its own, or the bytes as they are where the length's
    /// top bit is set.
    DvZip {
        inflate: Inflate,
        head: Vec<u8>,
        left: usize,
        stored: bool,
    },
}

impl Packing {
    /// By the upload's content type.
    pub fn of(content_type: &str) -> Result<Packing, Error> {
        if content_type.to_ascii_lowercase().contains("dvzip") {
            Ok(Packing(Kind::DvZip {
                inflate: Inflate::new(15)?,
                head: Vec::with_capacity(4),
                left: 0,
                stored: false,
            }))
        } else {
            Ok(Packing(Kind::Gzip(Inflate::new(31)?)))
        }
    }

    pub fn feed(
        &mut self,
        mut input: &[u8],
        sink: &mut dyn FnMut(&[u8]) -> Result<(), Error>,
    ) -> Result<(), Error> {
        match &mut self.0 {
            // What follows the stream's end is not the archive's.
            Kind::Gzip(inflate) => inflate.feed(input, sink).map(|_| ()),
            Kind::DvZip {
                inflate,
                head,
                left,
                stored,
            } => {
                while !input.is_empty() {
                    if *left == 0 {
                        let take = (4 - head.len()).min(input.len());
                        head.extend_from_slice(&input[..take]);
                        input = &input[take..];
                        if head.len() < 4 {
                            break;
                        }
                        let word = u32::from_be_bytes([head[0], head[1], head[2], head[3]]);
                        head.clear();
                        *stored = word & 0x8000_0000 != 0;
                        *left = (word & 0x7fff_ffff) as usize;
                        if *left > 64 << 20 {
                            return Err(Error::Bad("a piece of the upload is impossibly long"));
                        }
                        if !*stored {
                            inflate.again();
                        }
                        continue;
                    }
                    let take = (*left).min(input.len());
                    if *stored {
                        sink(&input[..take])?;
                    } else {
                        // Should the stream end before its piece does, the rest of the piece is nothing.
                        inflate.feed(&input[..take], sink)?;
                    }
                    *left -= take;
                    input = &input[take..];
                }
                Ok(())
            }
        }
    }
}

// ------------------------------------------------------------------- archive

extern "C" {
    fn renameat2(
        old_dir: c_int,
        old: *const c_char,
        new_dir: c_int,
        new: *const c_char,
        flags: u32,
    ) -> c_int;
}
const AT_FDCWD: c_int = -100;
const RENAME_NOREPLACE: u32 = 1;

/// Where an upload is unpacked: a hidden folder inside the one files are
/// received in, emptied into it when everything has arrived.
pub struct Landing {
    folder: PathBuf,
    staging: PathBuf,
    kept: bool,
}

impl Landing {
    pub fn new(folder: &Path) -> io::Result<Landing> {
        fs::create_dir_all(folder)?;
        let mut random = [0u8; 6];
        io::Read::read_exact(&mut File::open("/dev/urandom")?, &mut random)?;
        let name: String = random.iter().map(|b| format!("{b:02x}")).collect();
        let staging = folder.join(format!(".nova-airdrop-{name}"));
        fs::DirBuilder::new().mode(0o700).create(&staging)?;
        Ok(Landing {
            folder: folder.to_owned(),
            staging,
            kept: false,
        })
    }

    /// Moves what was unpacked into the folder, each thing under its own name
    /// or, where that is taken, the name with a number: nothing that was
    /// there is replaced. Says where each thing went.
    pub fn keep(mut self) -> io::Result<Vec<PathBuf>> {
        let mut names: Vec<_> = fs::read_dir(&self.staging)?
            .filter_map(|entry| entry.ok().map(|entry| entry.file_name()))
            .collect();
        names.sort();
        // Each thing by itself: one that cannot be placed does not take the others with it, which
        // are the user's from the moment they are moved.
        let (mut kept, mut failed) = (Vec::new(), None);
        for name in names {
            match self.settle(&name) {
                Ok(target) => kept.push(target),
                Err(error) => failed = Some(error),
            }
        }
        match failed {
            Some(error) if kept.is_empty() => Err(error),
            // What could not be placed goes with the staging folder.
            Some(_) => Ok(kept),
            None => {
                self.kept = true;
                fs::remove_dir(&self.staging)?;
                Ok(kept)
            }
        }
    }

    /// Moves one thing from the staging folder into the folder, under its name or its name with a number.
    fn settle(&self, name: &std::ffi::OsStr) -> io::Result<PathBuf> {
        let from = CString::new(self.staging.join(name).as_os_str().as_bytes())?;
        let path = Path::new(name);
        let mut stem = path
            .file_stem()
            .unwrap_or(name)
            .to_string_lossy()
            .into_owned();
        let extension = path
            .extension()
            .map(|e| format!(".{}", e.to_string_lossy()))
            .unwrap_or_default();
        // Room in a name's 255 bytes for the number: a name that fills them is shortened for it.
        let room = 255usize.saturating_sub(extension.len() + 7);
        while stem.len() > room {
            stem.pop();
        }
        let mut number = 1;
        loop {
            let target = if number == 1 {
                self.folder.join(name)
            } else {
                self.folder.join(format!("{stem} {number}{extension}"))
            };
            let to = CString::new(target.as_os_str().as_bytes())?;
            // SAFETY: both are NUL-terminated paths that live across the call.
            if unsafe {
                renameat2(
                    AT_FDCWD,
                    from.as_ptr(),
                    AT_FDCWD,
                    to.as_ptr(),
                    RENAME_NOREPLACE,
                )
            } == 0
            {
                return Ok(target);
            }
            let error = io::Error::last_os_error();
            if error.kind() != io::ErrorKind::AlreadyExists || number > 10_000 {
                return Err(error);
            }
            number += 1;
        }
    }
}

/// Takes away the staging folders a daemon that was killed left in a folder. For the one daemon
/// that receives into it, as it starts and as it ends.
pub fn sweep(folder: &Path) {
    let Ok(entries) = fs::read_dir(folder) else {
        return;
    };
    for entry in entries.flatten() {
        let ours = entry
            .file_name()
            .to_str()
            .and_then(|name| name.strip_prefix(".nova-airdrop-"))
            .is_some_and(|rest| rest.len() == 12 && rest.bytes().all(|b| b.is_ascii_hexdigit()));
        // A folder, and not a link to one: what is removed is what is in this folder.
        if ours && entry.file_type().is_ok_and(|kind| kind.is_dir()) {
            let _ = fs::remove_dir_all(entry.path());
        }
    }
}

impl Drop for Landing {
    fn drop(&mut self) {
        if !self.kept {
            let _ = fs::remove_dir_all(&self.staging);
        }
    }
}

/// A name in an archive, with its path, at its longest.
const NAME_LIMIT: usize = 4096;
/// More files and folders than this in one transfer is not one.
const ENTRY_LIMIT: usize = 20_000;

/// A cpio archive, in either of the formats its headers come in ("070707",
/// all octal, which is what AirDrop sends; "070701" and "070702", in hex and
/// padded to four bytes), unpacked as its bytes arrive.
pub struct Archive {
    root: PathBuf,
    buffer: Vec<u8>,
    state: State,
    /// How many bytes of files may still be written.
    allowance: u64,
    /// How many bytes of archive may still arrive, counting what is skipped and the headers.
    room: u64,
    entries: usize,
    pub files: usize,
    pub bytes: u64,
    pub skipped: Vec<String>,
}

enum State {
    Header,
    /// A file's bytes, then padding.
    Body {
        file: Option<File>,
        left: u64,
        padding: usize,
    },
    Done,
}

impl Archive {
    /// `announced` is how many bytes of files the sender said it would send.
    pub fn new(landing: &Landing, announced: u64) -> Archive {
        Archive {
            root: landing.staging.clone(),
            buffer: Vec::new(),
            state: State::Header,
            // Some room over what was said: a sender's sizes are of the files as it has them, and it may convert a photo on the way.
            allowance: Self::most(announced),
            room: Self::most(announced).saturating_add(16 << 20),
            entries: 0,
            files: 0,
            bytes: 0,
            skipped: Vec::new(),
        }
    }

    /// How many bytes of files a sender that announced so many may send.
    pub fn most(announced: u64) -> u64 {
        announced.saturating_mul(2).saturating_add(64 << 20)
    }

    pub fn done(&self) -> bool {
        matches!(self.state, State::Done)
    }

    pub fn feed(&mut self, mut data: &[u8]) -> Result<(), Error> {
        // Every byte counts, whether it is kept or not: an entry that is skipped is unpacked too.
        if !self.done() {
            self.room = self
                .room
                .checked_sub(data.len() as u64)
                .ok_or(Error::TooMuch)?;
        }
        loop {
            match &mut self.state {
                State::Done => return Ok(()),
                State::Body {
                    file,
                    left,
                    padding,
                } => {
                    // Straight from what arrived to the file: nothing of a file is held here.
                    let take = (*left).min(data.len() as u64) as usize;
                    if let Some(file) = file {
                        file.write_all(&data[..take])?;
                    }
                    *left -= take as u64;
                    data = &data[take..];
                    if *left > 0 {
                        return Ok(());
                    }
                    let skip = (*padding).min(data.len());
                    *padding -= skip;
                    data = &data[skip..];
                    if *padding > 0 {
                        return Ok(());
                    }
                    self.state = State::Header;
                }
                State::Header => {
                    // A header and its name are small: gathered whole before they are read, and
                    // never a byte more, since what follows them is a file's. How long they are
                    // shows in three steps: the first six bytes say which header, the header says
                    // how long the name is.
                    let whole = self.header_size();
                    // Said by the header itself, and believed only up to a name's length.
                    if whole.is_some_and(|whole| whole > 110 + NAME_LIMIT + 4) {
                        return Err(Error::Bad("a name in the upload is impossibly long"));
                    }
                    let target = whole.unwrap_or(match self.buffer.get(..6) {
                        None => 6,
                        Some(b"070707") => 76,
                        Some(_) => 110,
                    });
                    if self.buffer.len() < target {
                        if data.is_empty() {
                            return Ok(());
                        }
                        let take = (target - self.buffer.len()).min(data.len());
                        self.buffer.extend_from_slice(&data[..take]);
                        data = &data[take..];
                    } else if whole.is_some() {
                        self.entry()?;
                    }
                }
            }
        }
    }

    /// How many bytes the header in the buffer and its name take, once enough of it is there to say.
    fn header_size(&self) -> Option<usize> {
        let b = &self.buffer;
        if b.len() < 6 {
            return None;
        }
        if &b[..6] == b"070707" {
            (b.len() >= 76).then(|| 76 + number(&b[59..65], 8).unwrap_or(0) as usize)
        } else {
            // Hex headers: the header and the name together are padded to four bytes.
            (b.len() >= 110).then(|| (110 + number(&b[94..102], 16).unwrap_or(0) as usize + 3) & !3)
        }
    }

    fn entry(&mut self) -> Result<(), Error> {
        let b = std::mem::take(&mut self.buffer);
        let bad = Error::Bad("the upload is not a cpio archive");
        let (mode, size, name, padded) = match &b[..6] {
            b"070707" => {
                let field = |from: usize, to: usize| number(&b[from..to], 8);
                (field(18, 24), field(65, 76), &b[76..], false)
            }
            b"070701" | b"070702" => {
                let field = |from: usize, to: usize| number(&b[from..to], 16);
                let length =
                    field(94, 102).ok_or(Error::Bad("the upload is not a cpio archive"))? as usize;
                (
                    field(14, 22),
                    field(54, 62),
                    b.get(110..110 + length)
                        .ok_or(Error::Bad("the upload is not a cpio archive"))?,
                    true,
                )
            }
            _ => return Err(bad),
        };
        let (Some(mode), Some(size)) = (mode, size) else {
            return Err(bad);
        };
        if name.len() > NAME_LIMIT {
            return Err(Error::Bad("a name in the upload is impossibly long"));
        }
        let name = String::from_utf8_lossy(name.strip_suffix(&[0]).unwrap_or(name)).into_owned();
        self.entries += 1;
        if self.entries > ENTRY_LIMIT {
            return Err(Error::Bad("the upload has too many entries"));
        }
        if name == "TRAILER!!!" {
            self.state = State::Done;
            return Ok(());
        }
        let padding = if padded {
            (4 - (size % 4) as usize) % 4
        } else {
            0
        };
        let target = self.place(&name);
        let file = match (mode & 0o170000, target) {
            (0o040000, Some(path)) => {
                fs::create_dir_all(path)?;
                None
            }
            // A file, and not one of the "._name" companions macOS keeps a file's extra attributes in.
            (0o100000, Some(path)) if !name.rsplit('/').next().unwrap_or("").starts_with("._") => {
                self.allowance = self.allowance.checked_sub(size).ok_or(Error::TooMuch)?;
                if let Some(parent) = path.parent() {
                    fs::create_dir_all(parent)?;
                }
                self.files += 1;
                self.bytes += size;
                Some(
                    fs::OpenOptions::new()
                        .write(true)
                        .create_new(true)
                        .mode(0o644)
                        .open(path)?,
                )
            }
            // "." itself is the archive's first entry, and nothing to make.
            (0o040000, None) if name.trim_matches(['.', '/']).is_empty() => None,
            _ => {
                // Kept to be told about, and not without end.
                if self.skipped.len() < 16 {
                    self.skipped.push(name);
                }
                None
            }
        };
        self.state = State::Body {
            file,
            left: size,
            padding,
        };
        Ok(())
    }

    /// Where a name in the archive goes: under the root, or nowhere if it would leave it.
    fn place(&self, name: &str) -> Option<PathBuf> {
        let mut path = self.root.clone();
        let mut depth = 0;
        for part in name.split('/') {
            match part {
                "" | "." => {}
                ".." => return None,
                part if part.contains('\0') || depth >= 32 => return None,
                part => {
                    path.push(part);
                    depth += 1;
                }
            }
        }
        (depth > 0 && !name.starts_with('/')).then_some(path)
    }
}

fn number(digits: &[u8], radix: u32) -> Option<u64> {
    u64::from_str_radix(std::str::from_utf8(digits).ok()?, radix).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    extern "C" {
        fn compress2(
            dest: *mut u8,
            dest_len: *mut u64,
            source: *const u8,
            source_len: u64,
            level: c_int,
        ) -> c_int;
    }

    fn zlib(data: &[u8]) -> Vec<u8> {
        let mut out = vec![0u8; data.len() + data.len() / 100 + 64];
        let mut size = out.len() as u64;
        // SAFETY: both buffers are as long as they are said to be.
        assert_eq!(
            unsafe {
                compress2(
                    out.as_mut_ptr(),
                    &mut size,
                    data.as_ptr(),
                    data.len() as u64,
                    6,
                )
            },
            0
        );
        out.truncate(size as usize);
        out
    }

    /// An entry as AirDrop writes them: the old header, all octal.
    fn entry(name: &str, mode: u32, data: &[u8]) -> Vec<u8> {
        let mut out = format!(
            "070707{:06o}{:06o}{:06o}{:06o}{:06o}{:06o}{:06o}{:011o}{:06o}{:011o}",
            0,
            1,
            mode,
            501,
            20,
            1,
            0,
            0,
            name.len() + 1,
            data.len()
        )
        .into_bytes();
        out.extend_from_slice(name.as_bytes());
        out.push(0);
        out.extend_from_slice(data);
        out
    }

    fn photo(size: usize) -> Vec<u8> {
        // Nothing a packer can shrink.
        let mut state = 0x2545f4914f6cdd1du64;
        (0..size)
            .map(|_| {
                state ^= state << 13;
                state ^= state >> 7;
                state ^= state << 17;
                state as u8
            })
            .collect()
    }

    fn scratch(name: &str) -> PathBuf {
        let path =
            std::env::temp_dir().join(format!("nova-airdrop-test-{}-{name}", std::process::id()));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir_all(&path).unwrap();
        path
    }

    fn unpack(
        folder: &Path,
        packing: &str,
        packed: &[u8],
        announced: u64,
        step: usize,
    ) -> Result<(Archive, Vec<PathBuf>), Error> {
        let landing = Landing::new(folder)?;
        let mut archive = Archive::new(&landing, announced);
        let mut unpacker = Packing::of(packing)?;
        for piece in packed.chunks(step) {
            unpacker.feed(piece, &mut |plain| archive.feed(plain))?;
        }
        if !archive.done() {
            return Err(Error::Bad("the upload ended before its archive did"));
        }
        let kept = landing.keep()?;
        Ok((archive, kept))
    }

    fn dvzip(archive: &[u8]) -> Vec<u8> {
        // As an iPhone packs: 64 KiB at a time, each piece packed if that makes it smaller, else as it is.
        let mut out = Vec::new();
        for piece in archive.chunks(65536) {
            let packed = zlib(piece);
            if packed.len() < piece.len() {
                out.extend_from_slice(&(packed.len() as u32).to_be_bytes());
                out.extend_from_slice(&packed);
            } else {
                out.extend_from_slice(&(piece.len() as u32 | 0x8000_0000).to_be_bytes());
                out.extend_from_slice(piece);
            }
        }
        out
    }

    #[test]
    fn a_photo_packed_as_an_iphone_packs_arrives_whole() {
        let folder = scratch("dvzip");
        let picture = photo(1_044_468);
        let archive = [
            entry(".", 0o040755, b""),
            entry("./IMG_0001.HEIC", 0o100644, &picture),
            entry("./._IMG_0001.HEIC", 0o100644, &[7; 1746]),
            entry("TRAILER!!!", 0, b""),
        ]
        .concat();
        let packed = dvzip(&archive);
        assert!(
            packed[0] & 0x80 == 0 && packed[4..6] == [0x78, 0x9c],
            "the first piece is packed: the headers shrink"
        );
        // Whole, in the sizes TCP hands over, and a byte at a time through the first pieces.
        for step in [packed.len(), 1378, 7] {
            let (seen, kept) =
                unpack(&folder, "application/x-dvzip", &packed, 1_044_468, step).unwrap();
            assert_eq!((seen.files, seen.bytes), (1, 1_044_468));
            assert_eq!(seen.skipped, vec!["./._IMG_0001.HEIC"]);
            assert_eq!(fs::read(&kept[0]).unwrap(), picture);
        }
        // Three times the same name: none replaced.
        let mut names: Vec<_> = fs::read_dir(&folder)
            .unwrap()
            .map(|e| e.unwrap().file_name().into_string().unwrap())
            .collect();
        names.sort();
        assert_eq!(
            names,
            ["IMG_0001 2.HEIC", "IMG_0001 3.HEIC", "IMG_0001.HEIC"]
        );
        fs::remove_dir_all(&folder).unwrap();
    }

    #[test]
    fn a_folder_packed_with_gzip_arrives_as_a_folder() {
        let folder = scratch("gzip");
        let archive = [
            entry(".", 0o040755, b""),
            entry("./Trip", 0o040755, b""),
            entry("./Trip/a.txt", 0o100644, b"hello"),
            entry("./Trip/deep/b.txt", 0o100644, b""),
            entry("../escape.txt", 0o100644, b"no"),
            entry("/etc/absolute", 0o100644, b"no"),
            entry("./link", 0o120777, b"/etc/passwd"),
            entry("TRAILER!!!", 0, b""),
        ]
        .concat();
        let packed = gzip(&archive);
        let (seen, kept) = unpack(&folder, "application/x-cpio", &packed, 5, 100).unwrap();
        assert_eq!((seen.files, seen.bytes), (2, 5));
        assert_eq!(
            seen.skipped,
            vec!["../escape.txt", "/etc/absolute", "./link"]
        );
        assert_eq!(kept, vec![folder.join("Trip")]);
        assert_eq!(fs::read(folder.join("Trip/a.txt")).unwrap(), b"hello");
        assert_eq!(fs::read(folder.join("Trip/deep/b.txt")).unwrap(), b"");
        assert!(!folder.parent().unwrap().join("escape.txt").exists());
        fs::remove_dir_all(&folder).unwrap();
    }

    /// A gzip member around a zlib stream's middle: ten bytes of header, the deflated bytes, CRC-32 and length.
    fn gzip(data: &[u8]) -> Vec<u8> {
        extern "C" {
            fn crc32(crc: u64, buf: *const u8, len: u32) -> u64;
        }
        let packed = zlib(data);
        let mut out = vec![0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3];
        out.extend_from_slice(&packed[2..packed.len() - 4]);
        // SAFETY: the buffer is as long as it is said to be.
        out.extend_from_slice(
            &(unsafe { crc32(0, data.as_ptr(), data.len() as u32) } as u32).to_le_bytes(),
        );
        out.extend_from_slice(&(data.len() as u32).to_le_bytes());
        out
    }

    #[test]
    fn the_newer_header_is_read_too() {
        let folder = scratch("newc");
        let hex = |name: &str, mode: u32, data: &[u8]| {
            let mut out = format!("070701{:08x}{:08x}{:08x}{:08x}{:08x}{:08x}{:08x}{:08x}{:08x}{:08x}{:08x}{:08x}{:08x}", 1, mode, 0, 0, 1, 0, data.len(), 0, 0, 0, 0, name.len() + 1, 0).into_bytes();
            out.extend_from_slice(name.as_bytes());
            out.push(0);
            while out.len() % 4 != 0 {
                out.push(0);
            }
            out.extend_from_slice(data);
            while out.len() % 4 != 0 {
                out.push(0);
            }
            out
        };
        let archive = [
            hex("note.txt", 0o100644, b"seven b"),
            hex("b.txt", 0o100644, b"x"),
            hex("TRAILER!!!", 0, b""),
        ]
        .concat();
        let (seen, kept) = unpack(&folder, "application/x-cpio", &gzip(&archive), 8, 3).unwrap();
        assert_eq!((seen.files, seen.bytes, kept.len()), (2, 8, 2));
        assert_eq!(fs::read(folder.join("note.txt")).unwrap(), b"seven b");
        fs::remove_dir_all(&folder).unwrap();
    }

    #[test]
    fn what_fails_leaves_nothing_behind() {
        let folder = scratch("fails");
        let leftovers = |folder: &Path| fs::read_dir(folder).unwrap().count();
        // More than was announced (and the room on top of it).
        let big = [
            entry("./big.bin", 0o100644, &vec![0u8; 70 << 20]),
            entry("TRAILER!!!", 0, b""),
        ]
        .concat();
        assert!(matches!(
            unpack(&folder, "application/x-dvzip", &dvzip(&big), 1000, 65536),
            Err(Error::TooMuch)
        ));
        // Cut off in the middle of a file.
        let whole = dvzip(
            &[
                entry("./a.bin", 0o100644, &photo(200_000)),
                entry("TRAILER!!!", 0, b""),
            ]
            .concat(),
        );
        assert!(unpack(
            &folder,
            "application/x-dvzip",
            &whole[..100_000],
            200_000,
            4096
        )
        .is_err());
        // Not an archive; not packed as it says.
        assert!(unpack(
            &folder,
            "application/x-dvzip",
            &dvzip(&[b'x'; 500]),
            500,
            64
        )
        .is_err());
        assert!(unpack(
            &folder,
            "application/x-cpio",
            b"certainly not gzip, whatever it is",
            500,
            64
        )
        .is_err());
        assert!(unpack(
            &folder,
            "application/x-dvzip",
            &[0x7f, 0xff, 0xff, 0xff, 1, 2, 3],
            500,
            64
        )
        .is_err());
        assert_eq!(leftovers(&folder), 0);
        fs::remove_dir_all(&folder).unwrap();
    }

    #[test]
    fn a_name_said_to_be_endless_is_refused_before_it_is_gathered() {
        let folder = scratch("endless");
        let landing = Landing::new(&folder).unwrap();
        let mut archive = Archive::new(&landing, 0);
        // The newer header, its name four gigabytes by its own account.
        let mut header = b"070701".to_vec();
        header.extend_from_slice(&[b'0'; 88]);
        header.extend_from_slice(b"ffffffff");
        header.extend_from_slice(&[b'0'; 8]);
        assert_eq!(header.len(), 110);
        assert!(matches!(
            archive.feed(&header),
            Err(Error::Bad("a name in the upload is impossibly long"))
        ));
        assert!(archive.buffer.len() <= 110);
    }

    #[test]
    fn what_is_skipped_counts_against_what_may_arrive() {
        let folder = scratch("skipped");
        let landing = Landing::new(&folder).unwrap();
        // Nothing announced: sixty-four megabytes of files may come, and a little more of archive.
        let mut archive = Archive::new(&landing, 0);
        // A link, which is skipped, said to be eight gigabytes long.
        let mut link = entry("./link", 0o120777, b"");
        let size = link.len() - "./link".len() - 1 - 11;
        link[size..size + 11].copy_from_slice(b"77777777777");
        archive.feed(&link).unwrap();
        let megabyte = vec![0u8; 1 << 20];
        let mut fed = 0;
        let ended = loop {
            match archive.feed(&megabyte) {
                Ok(()) => fed += 1,
                Err(error) => break error,
            }
            assert!(fed < 200, "nothing stopped it");
        };
        assert!(matches!(ended, Error::TooMuch));
        assert!((64..=96).contains(&fed), "{fed}");
        drop(archive);
        drop(landing);
        assert_eq!(fs::read_dir(&folder).unwrap().count(), 0);
    }

    #[test]
    fn a_name_that_fills_its_room_is_shortened_for_its_number() {
        let folder = scratch("long");
        let long = format!("{}.txt", "n".repeat(251));
        assert_eq!(long.len(), 255);
        fs::write(folder.join(&long), b"first").unwrap();
        let archive = [
            entry(".", 0o040755, b""),
            entry(&format!("./{long}"), 0o100644, b"second"),
            entry("./other.txt", 0o100644, b"third"),
            entry("TRAILER!!!", 0, b""),
        ]
        .concat();
        let (_, kept) = unpack(&folder, "application/x-dvzip", &dvzip(&archive), 11, 4096).unwrap();
        assert_eq!(kept.len(), 2);
        let numbered = kept
            .iter()
            .find(|path| path.to_string_lossy().ends_with(" 2.txt"))
            .expect("the long name with a number");
        assert!(numbered.file_name().unwrap().len() <= 255);
        assert_eq!(fs::read(numbered).unwrap(), b"second");
        assert_eq!(fs::read(folder.join(&long)).unwrap(), b"first");
        assert_eq!(fs::read(folder.join("other.txt")).unwrap(), b"third");
    }

    #[test]
    fn what_a_killed_daemon_left_half_unpacked_is_swept_and_nothing_else() {
        let folder = scratch("sweep");
        let elsewhere = scratch("sweep-elsewhere");
        fs::write(elsewhere.join("precious"), b"kept").unwrap();
        let left = folder.join(".nova-airdrop-0123456789ab");
        fs::create_dir(&left).unwrap();
        fs::write(left.join("IMG_0001.HEIC"), b"half").unwrap();
        // Names that only look the part, a file with the name, and a link with it to somewhere else.
        fs::create_dir(folder.join(".nova-airdrop-mine")).unwrap();
        fs::create_dir(folder.join("nova-airdrop-0123456789ab")).unwrap();
        fs::write(folder.join(".nova-airdrop-aaaaaaaaaaaa"), b"a file").unwrap();
        std::os::unix::fs::symlink(&elsewhere, folder.join(".nova-airdrop-bbbbbbbbbbbb")).unwrap();
        sweep(&folder);
        let mut names: Vec<_> = fs::read_dir(&folder)
            .unwrap()
            .map(|entry| entry.unwrap().file_name().into_string().unwrap())
            .collect();
        names.sort();
        assert_eq!(
            names,
            [
                ".nova-airdrop-aaaaaaaaaaaa",
                ".nova-airdrop-bbbbbbbbbbbb",
                ".nova-airdrop-mine",
                "nova-airdrop-0123456789ab"
            ]
        );
        assert_eq!(fs::read(elsewhere.join("precious")).unwrap(), b"kept");
        // A folder that is not there is nothing to sweep.
        sweep(&folder.join("none"));
    }
}
