//! Small filesystem and encoding helpers.

use std::fs::{self, File};
use std::io::{self, ErrorKind};
use std::os::unix::fs::symlink;
use std::path::{Path, PathBuf};
use std::process;

use crate::error::{Context, Result};

/// The image types the background and the picker can show.
pub fn is_image(path: &Path) -> bool {
    path.extension().and_then(|e| e.to_str()).is_some_and(|e| {
        ["jpg", "jpeg", "png", "webp", "gif", "bmp", "svg"]
            .contains(&e.to_ascii_lowercase().as_str())
    })
}

/// `name` with `suffix` appended, beside the original.
fn sibling(path: &Path, suffix: &str) -> PathBuf {
    let mut name = path.file_name().unwrap_or_default().to_owned();
    name.push(suffix);
    path.with_file_name(name)
}

/// Writes through a temporary file and a rename, so readers see the old
/// contents or the new ones, never a partial file.
pub fn write_atomic(path: &Path, contents: impl AsRef<[u8]>) -> Result<()> {
    let tmp = sibling(path, &format!(".{}.tmp", process::id()));
    fs::write(&tmp, contents)
        .and_then(|()| fs::rename(&tmp, path))
        .inspect_err(|_| {
            let _ = fs::remove_file(&tmp);
        })
        .context(path.display())
}

/// Points `link` at `target` with one rename, which is atomic for a symlink
/// replacing a symlink.
pub fn replace_symlink(target: &Path, link: &Path) -> Result<()> {
    let tmp = sibling(link, ".new");
    remove_if_present(&tmp).context(tmp.display())?;
    symlink(target, &tmp)
        .and_then(|()| fs::rename(&tmp, link))
        .context(link.display())
}

pub fn remove_if_present(path: &Path) -> io::Result<()> {
    match fs::remove_file(path) {
        Err(e) if e.kind() == ErrorKind::NotFound => Ok(()),
        other => other,
    }
}

/// Copies the files of `src` into `dst`, recursively, replacing files that
/// exist. Symlinks are followed.
pub fn copy_tree(src: &Path, dst: &Path) -> Result<()> {
    fs::create_dir_all(dst).context(dst.display())?;
    for entry in fs::read_dir(src).context(src.display())? {
        let from = entry.context(src.display())?.path();
        let to = dst.join(from.file_name().unwrap_or_default());
        let meta = fs::metadata(&from).context(from.display())?;
        if meta.is_dir() {
            copy_tree(&from, &to)?;
        } else if meta.is_file() {
            fs::copy(&from, &to).context(from.display())?;
        }
    }
    Ok(())
}

/// Files directly in `dir` that are images, sorted by name. A missing
/// directory has none.
pub fn images_in(dir: &Path) -> Vec<PathBuf> {
    let Ok(entries) = fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut images: Vec<PathBuf> = entries
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| is_image(p) && p.is_file())
        // Picker rows are tab and newline separated text.
        .filter(|p| p.to_str().is_some_and(|s| !s.contains(['\t', '\n'])))
        .collect();
    images.sort();
    images
}

/// Holds the theme lock until dropped: one theme or background change at a
/// time, or two would race on the current/ links.
pub fn lock(path: &Path) -> Result<File> {
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir).context(dir.display())?;
    }
    let file = File::create(path).context(path.display())?;
    file.lock().context(path.display())?;
    Ok(file)
}

pub fn base64(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let n = chunk
            .iter()
            .enumerate()
            .fold(0u32, |n, (i, &b)| n | u32::from(b) << (16 - 8 * i));
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

/// FNV-1a: a stable hash for cache file names.
pub fn fnv1a(parts: &[&[u8]]) -> u64 {
    parts
        .iter()
        .flat_map(|p| p.iter())
        .fold(0xcbf2_9ce4_8422_2325, |h, &b| {
            (h ^ u64::from(b)).wrapping_mul(0x0100_0000_01b3)
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encodes_base64_with_padding() {
        assert_eq!(base64(b""), "");
        assert_eq!(base64(b"f"), "Zg==");
        assert_eq!(base64(b"fo"), "Zm8=");
        assert_eq!(base64(b"foo"), "Zm9v");
        assert_eq!(base64(b"foobar\n"), "Zm9vYmFyCg==");
    }

    #[test]
    fn hashes_like_reference_fnv1a() {
        assert_eq!(fnv1a(&[b""]), 0xcbf2_9ce4_8422_2325);
        assert_eq!(fnv1a(&[b"a"]), 0xaf63_dc4c_8601_ec8c);
        assert_eq!(fnv1a(&[b"fo", b"obar"]), fnv1a(&[b"foobar"]));
    }

    #[test]
    fn recognises_images() {
        assert!(is_image(Path::new("/a/b.JPG")));
        assert!(is_image(Path::new("nova.svg")));
        assert!(!is_image(Path::new("colors.toml")));
        assert!(!is_image(Path::new("jpg")));
    }
}
