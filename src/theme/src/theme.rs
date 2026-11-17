//! Rendering and switching themes.
//!
//! A theme is rendered into a fresh directory under rendered/, then
//! current/theme is pointed at it with one rename, so every reader sees either
//! the old theme or the new one. Nothing here needs root: the greeter and Chrome
//! follow through the user-owned mirror that nova-theme-apply keeps.

use std::fs;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::adaptive::{self, Mode};
use crate::background;
use crate::error::{bail, Context, Error, Result};
use crate::fsutil::{self, base64, copy_tree, replace_symlink, write_atomic};
use crate::image::Pixels;
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

/// "name\tbackground\tforeground\taccent" for each theme, for swatches. A
/// palette that does not load still lists its name, with empty colors.
pub fn list_colors(paths: &Paths) -> Vec<String> {
    list(paths)
        .into_iter()
        .map(|name| {
            let palette = palette_of(paths, &name);
            let color = |key| palette.as_ref().and_then(|p| p.get(key)).unwrap_or("");
            format!(
                "{name}\t{}\t{}\t{}",
                color("background"),
                color("foreground"),
                color("accent")
            )
        })
        .collect()
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

/// How large the adaptive theme reads a background: enough pixels for its
/// hues, few enough to weigh in a few milliseconds.
const SAMPLE_SIZE: u32 = 160;

/// Counted up when the adaptive theme's colors change for the same photo,
/// so that palettes kept from before are not used.
const ADAPTIVE_VERSION: u8 = 1;

/// Where the choice made in Settings is kept: "auto", "dark" or "light".
fn adaptive_choice(paths: &Paths) -> PathBuf {
    paths.state.join("adaptive")
}

/// "auto" is no mode: the photo's own.
fn parse_setting(word: &str) -> Option<Option<Mode>> {
    match word.trim() {
        "auto" => Some(None),
        other => Mode::parse(other).map(Some),
    }
}

/// A theme is adaptive when its colors.toml says `adaptive`: "auto", for
/// dark or light as the photo is, or one of the two to stay that. Then its
/// colors are taken from the background, and those in the file are for when
/// there is no photo to take them from. A choice made with `nova theme
/// adaptive` (Settings → Appearance) comes before the file's.
fn adaptive_setting(paths: &Paths, palette: &Palette) -> Option<Option<Mode>> {
    let written = palette.get("adaptive")?;
    let chosen = fs::read_to_string(adaptive_choice(paths))
        .ok()
        .and_then(|word| parse_setting(&word));
    Some(chosen.unwrap_or_else(|| parse_setting(written).unwrap_or(None)))
}

/// Whether the theme in use takes its colors from the background.
pub fn is_adaptive(paths: &Paths) -> bool {
    Palette::load(&paths.theme().join("colors.toml")).is_ok_and(|p| p.get("adaptive").is_some())
}

/// `nova theme adaptive`: prints whether the adaptive theme in use is dark,
/// light or as its photo is ("auto"); with one of those words, makes it so,
/// for every adaptive theme, and sets the one in use again.
pub fn adaptive(paths: &Paths, choice: Option<&str>) -> Result<()> {
    let Some(choice) = choice else {
        let palette = Palette::load(&paths.theme().join("colors.toml"))?;
        let Some(setting) = adaptive_setting(paths, &palette) else {
            bail!("the theme in use is not adaptive");
        };
        println!("{}", setting.map_or("auto", Mode::name));
        return Ok(());
    };
    if parse_setting(choice).is_none() {
        return Err(Error::usage("adaptive takes auto, dark or light"));
    }
    fs::create_dir_all(&paths.state).context(paths.state.display())?;
    write_atomic(&adaptive_choice(paths), format!("{}\n", choice.trim()))?;
    match current(paths) {
        Some(name) if is_adaptive(paths) => set(paths, &name),
        _ => Ok(()),
    }
}

/// The colors.toml the adaptive theme takes from `image`.
pub fn palette_from(paths: &Paths, image: &Path, mode: Option<Mode>) -> Result<String> {
    let pixels = Pixels::load(paths, image, SAMPLE_SIZE)?;
    let palette = adaptive::Palette::from_reading(&adaptive::read(&pixels.rgb, mode));
    let setting = mode.map_or("auto", Mode::name);
    Ok(format!(
        "{}adaptive = \"{setting}\"\n",
        palette.to_toml(&format!(
            "The adaptive theme's colors, taken from\n{}",
            image.display()
        ))
    ))
}

/// The same, kept by the image's path, size and time, so that a photo is
/// read once: Settings shows the theme's colors each time it opens.
fn adaptive_colors(paths: &Paths, image: &Path, mode: Option<Mode>) -> Result<String> {
    let (size, mtime, nsec) =
        fs::metadata(image).map_or((0, 0, 0), |m| (m.size(), m.mtime(), m.mtime_nsec()));
    let hash = fsutil::fnv1a(&[
        image.as_os_str().as_encoded_bytes(),
        &size.to_le_bytes(),
        &mtime.to_le_bytes(),
        &nsec.to_le_bytes(),
        mode.map_or("auto", Mode::name).as_bytes(),
        &[ADAPTIVE_VERSION],
    ]);
    let dir = paths.cache.join("adaptive");
    let kept = dir.join(format!("{hash:016x}.toml"));
    if let Ok(text) = fs::read_to_string(&kept) {
        return Ok(text);
    }
    let text = palette_from(paths, image, mode)?;
    if fs::create_dir_all(&dir).is_ok() {
        let _ = write_atomic(&kept, &text);
    }
    Ok(text)
}

/// The photo an adaptive theme named `name` would take its colors from: the
/// background chosen for it. The wordmark is not one: it is drawn in the
/// theme's own colors.
fn photo_for(paths: &Paths, name: &str) -> Option<PathBuf> {
    let image = background::chosen(paths, name)?;
    let rendered = fs::canonicalize(paths.rendered()).ok();
    let inside = image.starts_with(paths.theme())
        || fs::canonicalize(&image)
            .ok()
            .zip(rendered)
            .is_some_and(|(image, rendered)| image.starts_with(rendered));
    (!inside).then_some(image)
}

/// The colors a theme is drawn in: its colors.toml, or for an adaptive
/// theme with a photo behind it, the photo's.
fn palette_of(paths: &Paths, name: &str) -> Option<Palette> {
    let palette = Palette::load(&colors_file(paths, name)?).ok()?;
    let Some(mode) = adaptive_setting(paths, &palette) else {
        return Some(palette);
    };
    let taken = photo_for(paths, name)
        .and_then(|image| adaptive_colors(paths, &image, mode).ok())
        .map(|text| Palette::from_text(&text));
    Some(taken.unwrap_or(palette))
}

/// An adaptive theme staged in `stage` gets its colors from its photo. With
/// no photo, or one that cannot be read, it keeps the colors it came with.
fn adapt(paths: &Paths, name: &str, stage: &Path) -> Result<()> {
    let file = stage.join("colors.toml");
    let Some(mode) = adaptive_setting(paths, &Palette::load(&file)?) else {
        return Ok(());
    };
    let Some(image) = photo_for(paths, name) else {
        return Ok(());
    };
    match adaptive_colors(paths, &image, mode) {
        Ok(text) => fs::write(&file, text).context(file.display()),
        Err(e) => {
            eprintln!("nova-theme: {e}; the theme keeps the colors it came with");
            Ok(())
        }
    }
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
    adapt(paths, &name, &stage.path)?;
    render_dir(&stage.path, &templates(paths))?;
    write_atomic(&stage.path.join(MADE_FROM), made_from(paths, &name))?;
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

/// The file in a render that says what it was made from (`made_from`).
const MADE_FROM: &str = ".made-from";

/// What a render of the theme `name` is made from, a line for each file with
/// its size and when it last changed: the templates, the user's and Nova's,
/// and the theme's own files, Nova's and the user's. Nova's change with every
/// update of Nova.
fn made_from(paths: &Paths, name: &str) -> String {
    let mut files = templates(paths);
    for dir in sources(paths, name) {
        files_under(&dir, &mut files);
    }
    files
        .iter()
        .map(|file| match fs::metadata(file) {
            Ok(m) => format!(
                "{}\t{}\t{}.{:09}\n",
                file.display(),
                m.len(),
                m.mtime(),
                m.mtime_nsec()
            ),
            Err(_) => format!("{}\n", file.display()),
        })
        .collect()
}

/// Every file under `dir`, in order of name; a folder linked in is not
/// followed.
fn files_under(dir: &Path, out: &mut Vec<PathBuf>) {
    let mut entries: Vec<fs::DirEntry> = fs::read_dir(dir)
        .into_iter()
        .flatten()
        .filter_map(|e| e.ok())
        .collect();
    entries.sort_by_key(|e| e.file_name());
    for entry in entries {
        if entry.file_type().is_ok_and(|t| t.is_dir()) {
            files_under(&entry.path(), out);
        } else {
            out.push(entry.path());
        }
    }
}

/// The theme in use, rendered and applied again when what it is made from
/// has changed since: Nova's templates or the theme after an update of Nova,
/// or the user's own. Run as the session starts (data/hypr/autostart.lua), so
/// that a new template reaches a theme set before it. With no theme set, a
/// theme no longer installed, or a render up to date, nothing is done.
pub fn refresh(paths: &Paths) -> Result<()> {
    let Some(name) = current(paths) else {
        return Ok(());
    };
    if sources(paths, &name).is_empty() {
        return Ok(());
    }
    let kept = fs::read_to_string(paths.theme().join(MADE_FROM)).unwrap_or_default();
    if kept == made_from(paths, &name) {
        return Ok(());
    }
    set(paths, &name)
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
        let Some(palette) = palette_of(paths, name) else {
            continue;
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
