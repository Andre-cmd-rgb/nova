//! Backgrounds, and which one each theme uses.
//!
//! A theme offers its own backgrounds (the wordmark rendered in its palette),
//! the user's images for that theme in ~/.config/nova/backgrounds/<theme>/, and
//! the user's shared images in ~/.config/nova/backgrounds/.
//!
//! A theme remembers the background picked for it. A theme with no pick of its
//! own uses the latest shared image picked, so a photo stays put across theme
//! switches; failing that, its wordmark.

use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use crate::error::{bail, Context, Error, Result};
use crate::fsutil::{self, images_in, is_image, replace_symlink};
use crate::paths::Paths;
use crate::picker;
use crate::theme;

fn by_theme(paths: &Paths) -> PathBuf {
    paths.state.join("backgrounds/by-theme")
}

fn shared(paths: &Paths) -> PathBuf {
    paths.state.join("backgrounds/shared")
}

fn current_theme(paths: &Paths) -> Result<String> {
    theme::current(paths).ok_or_else(|| Error::new("no theme is set yet (see nova theme set)"))
}

/// The background last picked for `theme`, else the latest shared pick.
pub fn chosen(paths: &Paths, theme: &str) -> Option<PathBuf> {
    [by_theme(paths).join(theme), shared(paths)]
        .iter()
        .filter_map(|link| fs::read_link(link).ok())
        .find(|target| target.is_file())
}

/// Every background offered for the current theme, in display order.
pub fn list(paths: &Paths) -> Result<Vec<PathBuf>> {
    let theme = current_theme(paths)?;
    let user = paths.config.join("backgrounds");
    let mut images = images_in(&paths.theme().join("backgrounds"));
    images.extend(images_in(&user.join(&theme)));
    images.extend(images_in(&user));
    Ok(images)
}

pub fn current(paths: &Paths) -> Option<PathBuf> {
    fs::canonicalize(paths.background()).ok()
}

/// An image path as it should be stored: absolute, and through current/theme
/// when it lies inside the applied render, so it survives the next one.
fn stored_path(paths: &Paths, image: &Path) -> Result<PathBuf> {
    let absolute = if image.is_absolute() {
        image.to_path_buf()
    } else {
        env::current_dir()?.join(image)
    };
    let resolved = fs::canonicalize(&absolute).context(image.display())?;
    if !resolved.is_file() || !is_image(&resolved) {
        bail!("{}: not an image Nova can show", image.display());
    }
    if let Ok(render) = fs::canonicalize(paths.theme()) {
        if let Ok(inside) = resolved.strip_prefix(&render) {
            return Ok(paths.theme().join(inside));
        }
    }
    Ok(absolute)
}

pub fn set(paths: &Paths, image: &Path) -> Result<()> {
    let theme = current_theme(paths)?;
    let image = stored_path(paths, image)?;
    {
        let _lock = fsutil::lock(&paths.lock_file())?;
        replace_symlink(&image, &paths.background())?;
        let picks = by_theme(paths);
        fs::create_dir_all(&picks).context(picks.display())?;
        replace_symlink(&image, &picks.join(&theme))?;
        let theme_specific = image.starts_with(paths.theme())
            || image.starts_with(paths.config.join("backgrounds").join(&theme));
        if !theme_specific {
            replace_symlink(&image, &shared(paths))?;
        }
    }

    let resolved = fs::canonicalize(&image).context(image.display())?;
    let _ = Command::new("nova-shell")
        .args(["-q", "background", "set"])
        .arg(&resolved)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
    // The greeter shows the same background.
    let _ = Command::new("nova-theme-apply").arg("greeter").status();
    Ok(())
}

/// The position of the background in use within `images`.
fn position(paths: &Paths, images: &[PathBuf]) -> Option<usize> {
    let current = current(paths)?;
    images
        .iter()
        .position(|i| fs::canonicalize(i).is_ok_and(|i| i == current))
}

pub fn next(paths: &Paths) -> Result<()> {
    let images = list(paths)?;
    if images.is_empty() {
        bail!("no backgrounds to switch between");
    }
    let next = position(paths, &images).map_or(0, |i| (i + 1) % images.len());
    set(paths, &images[next])
}

/// Opens the background picker and applies the choice.
pub fn pick(paths: &Paths) -> Result<()> {
    let images = list(paths)?;
    let selected = position(paths, &images).map(|i| images[i].clone());
    let options = picker::Options {
        labels: false,
        filterable: false,
    };
    match picker::pick(paths, &images, selected.as_deref(), options)? {
        Some(choice) => set(paths, &choice),
        None => Ok(()),
    }
}
