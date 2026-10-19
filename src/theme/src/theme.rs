//! Rendering and switching themes.
//!
//! A theme is rendered into a fresh directory under rendered/, then
//! current/theme is pointed at it with one rename, so every reader sees either
//! the old theme or the new one. Nothing here needs root: the greeter and Chrome
//! follow through the user-owned mirror that nova-theme-apply keeps.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::background;
use crate::error::{bail, Context, Error, Result};
use crate::fsutil::{self, base64, copy_tree, replace_symlink, write_atomic};
use crate::palette::Palette;
use crate::paths::Paths;
use crate::picker;
use crate::template;

/// "Tokyo Night" and "tokyo-night" name the same theme.
pub fn slug(name: &str) -> Result<String> {
    let slug = name.trim().to_lowercase().replace(' ', "-");
    let mut chars = slug.chars();
    let valid = chars
        .next()
        .is_some_and(|c| c.is_ascii_lowercase() || c.is_ascii_digit())
        && chars
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || matches!(c, '.' | '_' | '-'));
    if !valid {
        return Err(Error::usage(format!("invalid theme name '{name}'")));
    }
    Ok(slug)
}

/// Nova's copy of a theme, then the user's, which wins file by file.
fn sources(paths: &Paths, name: &str) -> Vec<PathBuf> {
    [
        paths.share.join("themes").join(name),
        paths.config.join("themes").join(name),
    ]
    .into_iter()
    .filter(|d| d.is_dir())
    .collect()
}

/// The palette a theme renders with: the user's colors.toml if they have one.
fn colors_file(paths: &Paths, name: &str) -> Option<PathBuf> {
    sources(paths, name)
        .into_iter()
        .rev()
        .map(|d| d.join("colors.toml"))
        .find(|f| f.is_file())
}

pub fn list(paths: &Paths) -> Vec<String> {
    let mut names: Vec<String> = [paths.share.join("themes"), paths.config.join("themes")]
        .iter()
        .filter_map(|dir| fs::read_dir(dir).ok())
        .flatten()
        .filter_map(|e| e.ok())
        .filter(|e| e.path().join("colors.toml").is_file())
        .filter_map(|e| e.file_name().into_string().ok())
        .filter(|n| slug(n).is_ok_and(|s| &s == n))
        .collect();
    names.sort();
    names.dedup();
    names
}

pub fn current(paths: &Paths) -> Option<String> {
    let name = fs::read_to_string(paths.current().join("theme.name")).ok()?;
    Some(name.trim().to_owned()).filter(|n| !n.is_empty())
}

/// The user's templates come first, so they win over Nova's of the same name.
fn templates(paths: &Paths) -> Vec<PathBuf> {
    let in_dir = |dir: PathBuf| {
        let mut found: Vec<PathBuf> = fs::read_dir(dir)
            .into_iter()
            .flatten()
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| p.extension().is_some_and(|e| e == "tpl"))
            .collect();
        found.sort();
        found
    };
    let mut all = in_dir(paths.config.join("templates"));
    all.extend(in_dir(paths.share.join("templates")));
    all.push(paths.share.join("wordmark/nova.svg.tpl"));
    all.retain(|t| t.is_file());
    all
}

/// Renders each `<name>.tpl` into `dir/<name>` with `dir/colors.toml`, unless
/// `dir` already has `<name>`: a file the theme ships, or an earlier template.
/// Then each `shell.<section>.toml` the theme ships replaces that section of
/// shell.toml.
pub fn render_dir(dir: &Path, templates: &[PathBuf]) -> Result<()> {
    let palette = Palette::load(&dir.join("colors.toml"))?;
    for tpl in templates {
        let Some(name) = tpl
            .file_name()
            .and_then(|n| n.to_str())
            .and_then(|n| n.strip_suffix(".tpl"))
        else {
            bail!("{}: not a .tpl file", tpl.display());
        };
        let out = dir.join(name);
        if out.exists() {
            continue;
        }
        let text = fs::read_to_string(tpl).context(tpl.display())?;
        fs::write(&out, template::render(&text, &palette)).context(out.display())?;
    }

    let shell = dir.join("shell.toml");
    if !shell.is_file() {
        return Ok(());
    }
    let mut overrides: Vec<(String, PathBuf)> = fs::read_dir(dir)
        .context(dir.display())?
        .filter_map(|e| e.ok())
        .filter_map(|e| {
            let name = e.file_name().into_string().ok()?;
            let section = name.strip_prefix("shell.")?.strip_suffix(".toml")?;
            let valid = !section.is_empty()
                && section
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-');
            valid.then(|| (section.to_owned(), e.path()))
        })
        .collect();
    if overrides.is_empty() {
        return Ok(());
    }
    overrides.sort();
    let mut text = fs::read_to_string(&shell).context(shell.display())?;
    for (section, path) in overrides {
        text = template::replace_section(
            &text,
            &section,
            &fs::read_to_string(&path).context(path.display())?,
        );
    }
    fs::write(&shell, text).context(shell.display())
}

/// A render directory that is deleted unless it is kept.
struct Stage {
    path: PathBuf,
    keep: bool,
}

impl Stage {
    fn create(parent: &Path, name: &str) -> Result<Stage> {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or_default();
        let path = parent.join(format!("{name}.{stamp:x}"));
        fs::create_dir(&path).context(path.display())?;
        Ok(Stage { path, keep: false })
    }
}

impl Drop for Stage {
    fn drop(&mut self) {
        if !self.keep {
            let _ = fs::remove_dir_all(&self.path);
        }
    }
}

pub fn set(paths: &Paths, requested: &str) -> Result<()> {
    let name = slug(requested)?;
    let sources = sources(paths, &name);
    if sources.is_empty() {
        bail!("no theme named '{name}' (see nova theme list)");
    }
    let rendered = paths.rendered();
    for dir in [paths.current(), rendered.clone()] {
        fs::create_dir_all(&dir).context(dir.display())?;
    }
    let lock = fsutil::lock(&paths.lock_file())?;

    let mut stage = Stage::create(&rendered, &name)?;
    for src in &sources {
        copy_tree(src, &stage.path)?;
    }
    if !stage.path.join("colors.toml").is_file() {
        bail!("theme '{name}' has no colors.toml");
    }
    render_dir(&stage.path, &templates(paths))?;
    let backgrounds = stage.path.join("backgrounds");
    fs::create_dir_all(&backgrounds).context(backgrounds.display())?;
    let wordmark = stage.path.join("nova.svg");
    if wordmark.exists() {
        let target = backgrounds.join("nova.svg");
        if target.exists() {
            fs::remove_file(&wordmark)
        } else {
            fs::rename(&wordmark, &target)
        }
        .context(wordmark.display())?;
    }

    let previous = hold_previous_background(paths);

    let link = paths.theme();
    if fs::symlink_metadata(&link).is_ok_and(|m| m.is_dir()) {
        fs::remove_dir_all(&link).context(link.display())?;
    }
    replace_symlink(&stage.path, &link)?;
    stage.keep = true;
    write_atomic(&paths.current().join("theme.name"), format!("{name}\n"))?;
    for old in fs::read_dir(&rendered)
        .context(rendered.display())?
        .filter_map(|e| e.ok())
    {
        if old.path() != stage.path {
            let _ = fs::remove_dir_all(old.path());
        }
    }

    // Paths go through current/theme, so they survive the next render.
    let background =
        background::chosen(paths, &name).unwrap_or_else(|| link.join("backgrounds/nova.svg"));
    replace_symlink(&background, &paths.background())?;

    let colors = base64(&fs::read(link.join("colors.toml")).context("colors.toml")?);
    let shell = fs::read(link.join("shell.toml"))
        .map(|b| base64(&b))
        .unwrap_or_default();
    let resolved = fs::canonicalize(&background).unwrap_or_else(|_| background.clone());
    let transition = Command::new("nova-shell")
        .args(["-q", "background", "themeTransition"])
        .arg(previous.unwrap_or_default())
        .args([&resolved, &background])
        .args([colors, shell])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();
    drop(lock);

    let applied = Command::new("nova-theme-apply").status();
    if let Ok(mut child) = transition {
        let _ = child.wait();
    }
    let _ = Command::new("nova-hook")
        .args(["theme-set", &name])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
    match applied {
        Ok(status) if status.success() => Ok(()),
        Ok(_) => bail!("theme '{name}' is set, but some apps could not be updated"),
        Err(e) => bail!("theme '{name}' is set, but nova-theme-apply did not run: {e}"),
    }
}

/// The background in use before a switch, for the shell to cross-fade from.
/// One inside the old render is deleted with it, so it is held in the runtime
/// directory by a hard link, or a copy.
fn hold_previous_background(paths: &Paths) -> Option<PathBuf> {
    if let Ok(entries) = fs::read_dir(&paths.runtime) {
        for e in entries.filter_map(|e| e.ok()) {
            if e.file_name()
                .to_string_lossy()
                .starts_with("background-previous.")
            {
                let _ = fs::remove_file(e.path());
            }
        }
    }
    let old = fs::canonicalize(paths.background())
        .ok()
        .filter(|p| p.is_file())?;
    let rendered = fs::canonicalize(paths.rendered()).ok()?;
    if !old.starts_with(&rendered) {
        return Some(old);
    }
    fs::create_dir_all(&paths.runtime).ok()?;
    let ext = old.extension().and_then(|e| e.to_str()).unwrap_or("img");
    let held = paths.runtime.join(format!("background-previous.{ext}"));
    fs::hard_link(&old, &held)
        .or_else(|_| fs::copy(&old, &held).map(drop))
        .ok()?;
    Some(held)
}

/// One preview per theme: the wordmark in its palette, named `<theme>.svg` so
/// the picker labels it with the theme's name. Files are rewritten only when
/// they change, which keeps their thumbnails cached.
fn previews(paths: &Paths) -> Result<Vec<PathBuf>> {
    let tpl = paths.share.join("wordmark/nova.svg.tpl");
    let wordmark = fs::read_to_string(&tpl).context(tpl.display())?;
    let dir = paths.cache.join("theme-previews");
    fs::create_dir_all(&dir).context(dir.display())?;

    let names = list(paths);
    let mut previews = Vec::with_capacity(names.len());
    for name in &names {
        let Some(colors) = colors_file(paths, name) else {
            continue;
        };
        let palette = match Palette::load(&colors) {
            Ok(p) => p,
            Err(e) => {
                eprintln!("nova-theme: {e}");
                continue;
            }
        };
        let svg = template::render(&wordmark, &palette);
        let path = dir.join(format!("{name}.svg"));
        if fs::read_to_string(&path).ok().as_deref() != Some(svg.as_str()) {
            write_atomic(&path, svg)?;
        }
        previews.push(path);
    }

    for e in fs::read_dir(&dir)
        .context(dir.display())?
        .filter_map(|e| e.ok())
    {
        if !previews.contains(&e.path()) {
            let _ = fs::remove_file(e.path());
        }
    }
    Ok(previews)
}

/// Opens the theme picker and applies the choice.
pub fn pick(paths: &Paths) -> Result<()> {
    let previews = previews(paths)?;
    let selected = current(paths).and_then(|n| {
        previews
            .iter()
            .find(|p| p.file_stem().is_some_and(|s| *s == *n))
            .cloned()
    });
    let options = picker::Options {
        labels: true,
        filterable: true,
    };
    let Some(choice) = picker::pick(paths, &previews, selected.as_deref(), options)? else {
        return Ok(());
    };
    match choice.file_stem().and_then(|s| s.to_str()) {
        Some(name) => set(paths, name),
        None => bail!("the picker returned '{}'", choice.display()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalises_theme_names() {
        assert_eq!(slug("Tokyo Night").unwrap(), "tokyo-night");
        assert_eq!(slug("retro-82").unwrap(), "retro-82");
        assert!(slug("../etc").is_err());
        assert!(slug("").is_err());
        assert!(slug(".hidden").is_err());
    }
}
