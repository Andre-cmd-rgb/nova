//! The shell's image picker, driven over IPC.
//!
//! The picker shows small JPEG thumbnails, made once per image by vipsthumbnail
//! and cached by path, size and mtime. It reports a choice by writing the
//! chosen path to a selection file and then creating a done file.

use std::fs;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::process::{self, Command, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::thread;
use std::time::{Duration, Instant, SystemTime};

use crate::error::{bail, Context, Result};
use crate::fsutil::{base64, fnv1a, remove_if_present};
use crate::paths::Paths;

pub struct Options {
    /// Captions from file names ("tokyo-night.svg" reads "Tokyo Night").
    pub labels: bool,
    /// Typing filters the images by name.
    pub filterable: bool,
}

/// Thumbnails untouched this long are deleted when they are not in use.
const THUMBNAIL_MAX_AGE: Duration = Duration::from_secs(60 * 24 * 60 * 60);

/// Removes the request files however the picker ends.
struct Request {
    selection: PathBuf,
    done: PathBuf,
}

impl Drop for Request {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.selection);
        let _ = fs::remove_file(&self.done);
    }
}

/// Shows `images`, with `selected` highlighted, and returns the one picked, or
/// None when the picker is dismissed.
pub fn pick(
    paths: &Paths,
    images: &[PathBuf],
    selected: Option<&Path>,
    options: Options,
) -> Result<Option<PathBuf>> {
    if images.is_empty() {
        bail!("there is nothing to pick from");
    }
    let rows: Vec<String> = images
        .iter()
        .zip(thumbnails(paths, images))
        .map(|(image, thumb)| format!("{}\t{}", image.display(), thumb.display()))
        .collect();

    fs::create_dir_all(&paths.runtime).context(paths.runtime.display())?;
    let id = format!("picker.{}", process::id());
    let request = Request {
        selection: paths.runtime.join(format!("{id}.selection")),
        done: paths.runtime.join(format!("{id}.done")),
    };
    remove_if_present(&request.selection).context(request.selection.display())?;
    remove_if_present(&request.done).context(request.done.display())?;

    let flag = |on: bool| if on { "true" } else { "false" };
    let opened = Command::new("nova-shell")
        .args(["image-selector", "open", ""])
        .arg(base64(rows.join("\n").as_bytes()))
        .arg(selected.unwrap_or(Path::new("")))
        .args([&request.selection, &request.done])
        .args([flag(options.labels), flag(options.filterable)])
        .stdin(Stdio::null())
        .stderr(Stdio::inherit())
        .output()
        .context("nova-shell")?;
    if String::from_utf8_lossy(&opened.stdout).trim() != "ok" {
        bail!("the shell did not open the picker");
    }

    let mut checked = Instant::now();
    while !request.done.exists() {
        thread::sleep(Duration::from_millis(15));
        if checked.elapsed() > Duration::from_secs(2) {
            if !shell_running() {
                bail!("the shell exited while the picker was open");
            }
            checked = Instant::now();
        }
    }
    let choice = fs::read_to_string(&request.selection).unwrap_or_default();
    let choice = choice.trim_end_matches('\n');
    Ok((!choice.is_empty()).then(|| PathBuf::from(choice)))
}

/// Whether a Quickshell process is alive for this user.
fn shell_running() -> bool {
    let Ok(entries) = fs::read_dir("/proc") else {
        return true;
    };
    let uid = fs::metadata("/proc/self").map(|m| m.uid()).ok();
    entries.filter_map(|e| e.ok()).any(|e| {
        let ours = e.metadata().is_ok_and(|m| Some(m.uid()) == uid);
        ours && fs::read_to_string(e.path().join("comm"))
            .is_ok_and(|c| matches!(c.trim_end(), "qs" | "quickshell"))
    })
}

/// A thumbnail for each image, generated in parallel where missing. An image
/// whose thumbnail cannot be made is shown as itself.
fn thumbnails(paths: &Paths, images: &[PathBuf]) -> Vec<PathBuf> {
    let dir = paths.cache.join("thumbnails");
    if fs::create_dir_all(&dir).is_err() {
        return images.to_vec();
    }
    let planned: Vec<PathBuf> = images.iter().map(|i| thumbnail_path(&dir, i)).collect();
    let missing: Vec<(&PathBuf, &PathBuf)> = images
        .iter()
        .zip(&planned)
        .filter(|(_, t)| !t.exists())
        .collect();

    if !missing.is_empty() {
        let next = AtomicUsize::new(0);
        let workers = thread::available_parallelism()
            .map_or(4, |n| n.get())
            .min(missing.len());
        thread::scope(|scope| {
            for _ in 0..workers {
                scope.spawn(|| {
                    while let Some((image, thumb)) =
                        missing.get(next.fetch_add(1, Ordering::Relaxed))
                    {
                        generate(image, thumb);
                    }
                });
            }
        });
    }

    prune(&dir, &planned);
    images
        .iter()
        .zip(planned)
        .map(|(i, t)| if t.exists() { t } else { i.clone() })
        .collect()
}

fn thumbnail_path(dir: &Path, image: &Path) -> PathBuf {
    let (size, mtime, nsec) =
        fs::metadata(image).map_or((0, 0, 0), |m| (m.size(), m.mtime(), m.mtime_nsec()));
    let hash = fnv1a(&[
        image.as_os_str().as_encoded_bytes(),
        &size.to_le_bytes(),
        &mtime.to_le_bytes(),
        &nsec.to_le_bytes(),
    ]);
    dir.join(format!("{hash:016x}.jpg"))
}

/// Each vipsthumbnail runs single-threaded; the callers fan out one per image.
fn generate(image: &Path, thumb: &Path) {
    let tmp = thumb.with_extension(format!("{}.jpg", process::id()));
    let made = Command::new("vipsthumbnail")
        .arg(image)
        .args(["--size", "1536x864", "--smartcrop", "centre", "--path"])
        .arg(format!("{}[Q=82,strip]", tmp.display()))
        .env("VIPS_CONCURRENCY", "1")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|s| s.success());
    if !(made && fs::rename(&tmp, thumb).is_ok()) {
        let _ = fs::remove_file(&tmp);
    }
}

fn prune(dir: &Path, in_use: &[PathBuf]) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    let now = SystemTime::now();
    for path in entries.filter_map(|e| e.ok().map(|e| e.path())) {
        let old = fs::metadata(&path)
            .and_then(|m| m.modified())
            .is_ok_and(|t| now.duration_since(t).unwrap_or_default() > THUMBNAIL_MAX_AGE);
        if old && !in_use.contains(&path) {
            let _ = fs::remove_file(&path);
        }
    }
}
