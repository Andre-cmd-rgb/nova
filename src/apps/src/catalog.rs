//! The App Center's catalog: every app from Arch's repositories, Flathub and
//! Nova's own builds, each app once with where it can come from, the source
//! it is offered from first.
//!
//! An app in more than one is matched by its AppStream ID, or an ID it was
//! known by. The order of the sources is the one place that decides which
//! is offered: Nova's build (Chrome and VS Code, from their makers'
//! releases), then Arch's package, then Flathub. Arch's comes before
//! Flathub's because it is the one Nova's theme reaches, is in the Arch
//! snapshot the release was tested against, and costs least: GIMP is 43 MB
//! from Arch, and 103 MB from Flathub with a 433 MB runtime besides
//! (docs/apps.md has the measurements). The app's page offers the other.

use std::collections::HashMap;

use crate::appstream::{Component, Shot};
use crate::json::Object;

/// Where an app can be installed from.
#[derive(Debug, Clone, PartialEq)]
pub enum Source {
    /// Built here from its maker's release by `nova apps install`.
    Nova { package: String, maker: String },
    /// A package in Arch's repositories, as the release pins them, and the
    /// desktop entry it installs, which can be named otherwise than
    /// Flathub's (firefox.desktop, org.mozilla.firefox.desktop).
    Arch {
        package: String,
        repo: String,
        version: String,
        desktop: String,
    },
    /// A Flathub app: its ref, and what its download and the runtime it
    /// needs come to.
    Flathub {
        app: String,
        reference: String,
        version: String,
        download: u64,
        installed: u64,
        runtime: String,
        verified: bool,
    },
}

impl Source {
    pub fn kind(&self) -> &'static str {
        match self {
            Source::Nova { .. } => "nova",
            Source::Arch { .. } => "arch",
            Source::Flathub { .. } => "flathub",
        }
    }

    fn order(&self) -> u8 {
        match self {
            Source::Nova { .. } => 0,
            Source::Arch { .. } => 1,
            Source::Flathub { .. } => 2,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct App {
    pub meta: Component,
    pub icon: String,
    pub category: &'static str,
    pub sources: Vec<Source>,
    /// Its place on the front page: the category it is shown in there, and
    /// its position, from 1.
    pub featured: Option<(String, usize)>,
    /// Its place in the Popular row above the categories, from 1; an app
    /// can be there and in a category's.
    pub popular: Option<usize>,
    pub rank: u64,
}

/// The categories, in the store's order: its key, and the freedesktop
/// categories that put an app in it, the first that matches winning.
pub const CATEGORIES: &[(&str, &[&str])] = &[
    ("play", &["Game"]),
    (
        "develop",
        &[
            "Development",
            "IDE",
            "Debugger",
            "RevisionControl",
            "WebDevelopment",
            "Profiling",
        ],
    ),
    (
        "create",
        &[
            "Graphics",
            "2DGraphics",
            "3DGraphics",
            "Photography",
            "RasterGraphics",
            "VectorGraphics",
            "Publishing",
        ],
    ),
    (
        "media",
        &[
            "AudioVideo",
            "Audio",
            "Video",
            "Music",
            "Player",
            "Recorder",
            "AudioVideoEditing",
            "TV",
            "Midi",
            "Mixer",
        ],
    ),
    (
        "work",
        &[
            "Office",
            "WordProcessor",
            "Spreadsheet",
            "Presentation",
            "Finance",
            "ProjectManagement",
            "Calendar",
            "ContactManagement",
        ],
    ),
    (
        "internet",
        &[
            "Network",
            "WebBrowser",
            "Email",
            "Chat",
            "InstantMessaging",
            "IRCClient",
            "Feed",
            "FileTransfer",
            "P2P",
            "VideoConference",
            "Telephony",
            "News",
        ],
    ),
    (
        "learn",
        &[
            "Education",
            "Science",
            "Math",
            "Astronomy",
            "Languages",
            "Geography",
            "Chemistry",
            "Physics",
            "Biology",
            "Geoscience",
            "History",
        ],
    ),
];

pub fn category_of(categories: &[String]) -> &'static str {
    for (key, names) in CATEGORIES {
        if categories.iter().any(|c| names.contains(&c.as_str())) {
            return key;
        }
    }
    "utilities"
}

/// An app Nova builds from its maker's release (nova apps install): its
/// package, the Flathub ID its description and pictures are taken from, and
/// what the store says before Flathub's catalog is there.
pub struct Recipe {
    pub package: &'static str,
    pub id: &'static str,
    pub name: &'static str,
    pub summary: &'static str,
    pub maker: &'static str,
    pub desktop: &'static str,
    pub icon_name: &'static str,
    pub category: &'static str,
}

pub const RECIPES: &[Recipe] = &[
    Recipe {
        package: "google-chrome",
        id: "com.google.Chrome",
        name: "Google Chrome",
        summary: "The browser built by Google",
        maker: "Google",
        desktop: "google-chrome.desktop",
        icon_name: "google-chrome",
        category: "internet",
    },
    Recipe {
        package: "visual-studio-code-bin",
        id: "com.visualstudio.code",
        name: "Visual Studio Code",
        summary: "Code editing. Redefined.",
        maker: "Microsoft",
        desktop: "code.desktop",
        icon_name: "visual-studio-code",
        category: "develop",
    },
];

/// What a Flathub ref comes to: its version, download and size installed,
/// and the runtime it needs.
#[derive(Debug, Default, Clone, PartialEq)]
pub struct RefInfo {
    pub version: String,
    pub download: u64,
    pub installed: u64,
    pub runtime: String,
}

pub struct Inputs {
    /// Flathub's catalog, and the folder of its icons (…/active/icons).
    pub flathub: Vec<Component>,
    pub flathub_icons: String,
    /// What `flatpak remote-ls` says of each ref, apps and runtimes.
    pub refs: HashMap<String, RefInfo>,
    /// Arch's catalog, each with the repository it is from.
    pub arch: Vec<(Component, String)>,
    /// The packages in the sync databases now: name -> (repo, version).
    pub packages: HashMap<String, (String, String)>,
    /// Arch's icons as files the shell can draw, by repository and file
    /// name (made from Arch's JPEG XL ones).
    pub arch_icons: HashMap<(String, String), String>,
    /// "category id" lines: the front page.
    pub featured: Vec<(String, String)>,
}

fn file_exists(path: &str) -> bool {
    std::path::Path::new(path).is_file()
}

fn flathub_icon(dir: &str, c: &Component) -> String {
    if c.icon_file.is_empty() || dir.is_empty() {
        return String::new();
    }
    for size in ["128x128", "64x64"] {
        let path = format!("{dir}/{size}/{}", c.icon_file);
        if file_exists(&path) {
            return path;
        }
    }
    String::new()
}

/// What an ID matches, lowercase: itself, and without the ".desktop" an
/// older one ends in ("gimp.desktop" is GIMP's "org.gimp.GIMP" in an alias).
fn id_keys(id: &str) -> Vec<String> {
    let id = id.to_ascii_lowercase();
    match id.strip_suffix(".desktop") {
        Some(short) if !short.is_empty() => vec![short.to_string(), id],
        _ => vec![id],
    }
}

/// Every key an app's IDs and aliases match.
pub fn keys(c: &Component) -> Vec<String> {
    std::iter::once(&c.id)
        .chain(c.aliases.iter())
        .flat_map(|i| id_keys(i))
        .collect()
}

/// The Flathub app an Arch app is under another ID: one of the same name
/// whose ID has the package's name as one of its parts, as Bitwarden is
/// "bitwarden.desktop" from the package bitwarden in Arch's catalog, and
/// "com.bitwarden.desktop" in Flathub's. A name alone is not enough: two
/// apps called Notes are seldom one.
fn same_name(apps: &[App], by_name: &HashMap<String, Vec<usize>>, c: &Component) -> Option<usize> {
    let package = c.package.to_ascii_lowercase();
    by_name
        .get(&c.name.to_lowercase())?
        .iter()
        .copied()
        .find(|&at| {
            let app = &apps[at];
            app.sources.iter().all(|s| s.kind() == "flathub")
                && app
                    .meta
                    .id
                    .to_ascii_lowercase()
                    .split('.')
                    .any(|part| part == package)
        })
}

/// Fills in what the first left empty from the second.
fn enrich(base: &mut Component, other: &Component) {
    macro_rules! take {
        ($($f:ident),*) => { $( if base.$f.is_empty() { base.$f = other.$f.clone(); } )* };
    }
    take!(
        summary,
        developer,
        description,
        categories,
        keywords,
        license,
        homepage,
        desktop,
        icon_name,
        shots,
        version
    );
}

pub fn build(inputs: &Inputs) -> Vec<App> {
    let mut apps: Vec<App> = Vec::new();
    // Every ID and alias, lowercase, to the app it names.
    let mut by_id: HashMap<String, usize> = HashMap::new();

    let find = |by_id: &HashMap<String, usize>, c: &Component| -> Option<usize> {
        keys(c).iter().find_map(|k| by_id.get(k).copied())
    };
    let index = |by_id: &mut HashMap<String, usize>, c: &Component, at: usize| {
        for k in keys(c) {
            by_id.entry(k).or_insert(at);
        }
    };

    for c in &inputs.flathub {
        if c.bundle.is_empty() || find(&by_id, c).is_some() {
            continue;
        }
        let info = inputs.refs.get(&c.bundle).cloned().unwrap_or_default();
        let app_id = c.bundle.split('/').nth(1).unwrap_or(&c.id).to_string();
        let source = Source::Flathub {
            app: app_id,
            reference: c.bundle.clone(),
            version: if info.version.is_empty() {
                c.version.clone()
            } else {
                info.version
            },
            download: info.download,
            installed: info.installed,
            runtime: if info.runtime.is_empty() {
                c.runtime.clone()
            } else {
                info.runtime
            },
            verified: c.verified,
        };
        let at = apps.len();
        apps.push(App {
            icon: flathub_icon(&inputs.flathub_icons, c),
            category: category_of(&c.categories),
            meta: c.clone(),
            sources: vec![source],
            featured: None,
            popular: None,
            rank: 0,
        });
        index(&mut by_id, c, at);
    }
    let mut by_name: HashMap<String, Vec<usize>> = HashMap::new();
    for (at, app) in apps.iter().enumerate() {
        by_name
            .entry(app.meta.name.to_lowercase())
            .or_default()
            .push(at);
    }

    for (c, repo) in &inputs.arch {
        if c.package.is_empty() {
            continue;
        }
        // In the catalog, and in the release's repositories too.
        let Some((repo_now, version)) = inputs.packages.get(&c.package) else {
            continue;
        };
        let desktop = if c.desktop.is_empty() && c.id.ends_with(".desktop") {
            c.id.clone()
        } else {
            c.desktop.clone()
        };
        let source = Source::Arch {
            package: c.package.clone(),
            repo: repo_now.clone(),
            version: version.clone(),
            desktop,
        };
        let icon = inputs
            .arch_icons
            .get(&(repo.clone(), c.icon_file.clone()))
            .cloned()
            .unwrap_or_default();
        match find(&by_id, c).or_else(|| same_name(&apps, &by_name, c)) {
            Some(at) => {
                let app = &mut apps[at];
                if app.sources.iter().any(|s| s.kind() == "arch") {
                    continue;
                }
                app.sources.push(source);
                enrich(&mut app.meta, c);
                if app.icon.is_empty() {
                    app.icon = icon;
                }
                index(&mut by_id, c, at);
            }
            None => {
                let at = apps.len();
                apps.push(App {
                    icon,
                    category: category_of(&c.categories),
                    meta: c.clone(),
                    sources: vec![source],
                    featured: None,
                    popular: None,
                    rank: 0,
                });
                index(&mut by_id, c, at);
            }
        }
    }

    // Nova's builds: the app Flathub has under that ID becomes Nova's,
    // with Flathub's words and pictures, and Nova's build its one source.
    for r in RECIPES {
        let source = Source::Nova {
            package: r.package.into(),
            maker: r.maker.into(),
        };
        let probe = Component {
            id: r.id.into(),
            ..Default::default()
        };
        match find(&by_id, &probe) {
            Some(at) => {
                let app = &mut apps[at];
                app.sources = vec![source];
                app.meta.name = r.name.into();
                app.meta.desktop = r.desktop.into();
                app.meta.icon_name = r.icon_name.into();
                app.meta.developer = r.maker.into();
                app.category = r.category;
            }
            None => {
                let meta = Component {
                    id: r.id.into(),
                    name: r.name.into(),
                    summary: r.summary.into(),
                    developer: r.maker.into(),
                    desktop: r.desktop.into(),
                    icon_name: r.icon_name.into(),
                    ..Default::default()
                };
                let at = apps.len();
                apps.push(App {
                    meta,
                    icon: String::new(),
                    category: r.category,
                    sources: vec![source],
                    featured: None,
                    popular: None,
                    rank: 0,
                });
                by_id.insert(r.id.to_ascii_lowercase(), at);
            }
        }
    }

    let mut position: HashMap<&str, usize> = HashMap::new();
    let mut popular = 0;
    for (cat, id) in &inputs.featured {
        if let Some(at) = id_keys(id).iter().find_map(|k| by_id.get(k).copied()) {
            if cat == POPULAR {
                if apps[at].popular.is_none() {
                    popular += 1;
                    apps[at].popular = Some(popular);
                }
                continue;
            }
            if apps[at].featured.is_some() {
                continue;
            }
            let n = position.entry(cat.as_str()).or_insert(0);
            *n += 1;
            apps[at].featured = Some((cat.clone(), *n));
            if let Some(k) = CATEGORIES
                .iter()
                .map(|(k, _)| *k)
                .chain(["utilities"])
                .find(|k| *k == cat)
            {
                apps[at].category = k;
            }
        }
    }

    for app in &mut apps {
        app.sources.sort_by_key(Source::order);
        app.rank = rank(app);
    }
    apps.sort_by(|a, b| {
        b.rank
            .cmp(&a.rank)
            .then_with(|| a.meta.name.to_lowercase().cmp(&b.meta.name.to_lowercase()))
    });
    apps
}

/// How far up a list an app goes when nothing else orders it: with no
/// count of downloads to go by, what says an app is cared for. One the front
/// page shows first, in its order; then Nova's builds; one in both Arch and
/// Flathub; one Arch packages; one whose maker Flathub checked; one with
/// pictures and words to show.
pub fn rank(app: &App) -> u64 {
    let mut r = 0;
    if let Some((_, n)) = &app.featured {
        r += 1000 - (*n as u64).min(100);
    }
    let has = |kind: &str| app.sources.iter().any(|s| s.kind() == kind);
    if has("nova") {
        r += 60;
    }
    if has("arch") {
        r += 25;
        if has("flathub") {
            r += 20;
        }
    }
    if app
        .sources
        .iter()
        .any(|s| matches!(s, Source::Flathub { verified: true, .. }))
    {
        r += 20;
    }
    if !app.meta.shots.is_empty() {
        r += 10;
    }
    if !app.meta.description.is_empty() {
        r += 5;
    }
    if !app.icon.is_empty() {
        r += 5;
    }
    r
}

fn write_shots(out: &mut String, shots: &[Shot]) {
    out.push('[');
    for (i, s) in shots.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        Object::new(out)
            .str("url", &s.url)
            .some("caption", &s.caption)
            .end();
    }
    out.push(']');
}

fn write_source(out: &mut String, s: &Source) {
    let mut o = Object::new(out);
    o.str("kind", s.kind());
    match s {
        Source::Nova { package, maker } => {
            o.str("package", package).str("maker", maker);
        }
        Source::Arch {
            package,
            repo,
            version,
            desktop,
        } => {
            o.str("package", package)
                .str("repo", repo)
                .some("version", version)
                .some("desktop", desktop);
        }
        Source::Flathub {
            app,
            reference,
            version,
            download,
            installed,
            runtime,
            verified,
        } => {
            o.str("app", app)
                .str("ref", reference)
                .some("version", version);
            o.num("download", *download)
                .num("installed", *installed)
                .some("runtime", runtime)
                .bool("verified", *verified);
        }
    }
    o.end();
}

pub fn write_app(out: &mut String, app: &App) {
    let m = &app.meta;
    let mut o = Object::new(out);
    o.str("id", &m.id)
        .str("name", &m.name)
        .some("summary", &m.summary)
        .some("developer", &m.developer);
    o.str("category", app.category);
    o.some("icon", &app.icon)
        .some("iconName", &m.icon_name)
        .some("desktop", &m.desktop);
    if !m.keywords.is_empty() {
        o.str("keywords", &m.keywords.join(" "));
    }
    o.some("license", &m.license).some("homepage", &m.homepage);
    if !m.description.is_empty() {
        o.strs("description", &m.description);
    }
    if !m.shots.is_empty() {
        o.raw("shots", |out| write_shots(out, &m.shots));
    }
    o.raw("sources", |out| {
        out.push('[');
        for (i, s) in app.sources.iter().enumerate() {
            if i > 0 {
                out.push(',');
            }
            write_source(out, s);
        }
        out.push(']');
    });
    if let Some((cat, n)) = &app.featured {
        o.str("featured", cat).num("position", *n as u64);
    }
    if let Some(n) = app.popular {
        o.num("popular", n as u64);
    }
    o.num("rank", app.rank);
    o.end();
}

/// The whole catalog: when it was made, which catalogs it was made from,
/// the runtimes' sizes, and the apps.
pub fn write(apps: &[App], inputs: &Inputs, built: u64) -> String {
    let mut out = String::with_capacity(apps.len() * 1200);
    let mut o = Object::new(&mut out);
    o.num("format", 1).num("built", built);
    o.bool("flathub", !inputs.flathub.is_empty())
        .bool("arch", !inputs.arch.is_empty());
    o.raw("runtimes", |out| {
        let mut runtimes: Vec<(&String, &RefInfo)> = inputs
            .refs
            .iter()
            .filter(|(r, _)| r.starts_with("runtime/"))
            .collect();
        runtimes.sort_by(|a, b| a.0.cmp(b.0));
        let mut r = Object::new(out);
        for (reference, info) in runtimes {
            let name = reference.trim_start_matches("runtime/");
            r.raw(name, |out| {
                Object::new(out)
                    .num("download", info.download)
                    .num("installed", info.installed)
                    .end();
            });
        }
        r.end();
    });
    o.raw("apps", |out| {
        out.push('[');
        for (i, app) in apps.iter().enumerate() {
            if i > 0 {
                out.push_str(",\n");
            }
            write_app(out, app);
        }
        out.push(']');
    });
    o.end();
    out.push('\n');
    out
}

/// "102.5 MB", "1.1 GB", "344.1 kB", "512 bytes", as flatpak prints a size,
/// in bytes.
pub fn parse_size(text: &str) -> u64 {
    let text = text.replace('\u{a0}', " ");
    let mut parts = text.split_whitespace();
    let (Some(number), unit) = (parts.next(), parts.next().unwrap_or("bytes")) else {
        return 0;
    };
    let Ok(n) = number.parse::<f64>() else {
        return 0;
    };
    let scale = match unit {
        "kB" => 1e3,
        "MB" => 1e6,
        "GB" => 1e9,
        "TB" => 1e12,
        _ => 1.0,
    };
    (n * scale).round() as u64
}

/// `flatpak remote-ls --columns=ref,version,download-size,installed-size,runtime`,
/// a ref to a line.
pub fn parse_refs(text: &str) -> HashMap<String, RefInfo> {
    let mut refs = HashMap::new();
    for line in text.lines() {
        let f: Vec<&str> = line.split('\t').collect();
        if f.len() < 4 || !(f[0].starts_with("app/") || f[0].starts_with("runtime/")) {
            continue;
        }
        refs.insert(
            f[0].to_string(),
            RefInfo {
                version: f[1].trim().to_string(),
                download: parse_size(f[2]),
                installed: parse_size(f[3]),
                runtime: f.get(4).map(|r| r.trim().to_string()).unwrap_or_default(),
            },
        );
    }
    refs
}

/// `pacman -Sl`: "repo name version [installed]" lines, to name -> (repo,
/// version), the first repository that has a package winning, as pacman's
/// order does.
pub fn parse_packages(text: &str) -> HashMap<String, (String, String)> {
    let mut packages = HashMap::new();
    for line in text.lines() {
        let mut f = line.split_whitespace();
        if let (Some(repo), Some(name), Some(version)) = (f.next(), f.next(), f.next()) {
            packages
                .entry(name.to_string())
                .or_insert((repo.to_string(), version.to_string()));
        }
    }
    packages
}

/// The key of the front page's row above the categories, which is not a
/// category: the best-known apps of every kind.
pub const POPULAR: &str = "popular";

/// The front page's list: "category id" lines, the category being a
/// category's key or `popular`; # starts a comment.
pub fn parse_featured(text: &str) -> Vec<(String, String)> {
    text.lines()
        .map(|l| l.split('#').next().unwrap_or("").trim())
        .filter_map(|l| {
            let mut f = l.split_whitespace();
            Some((f.next()?.to_string(), f.next()?.to_string()))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn comp(id: &str, name: &str) -> Component {
        Component {
            id: id.into(),
            name: name.into(),
            ..Default::default()
        }
    }

    fn inputs() -> Inputs {
        let mut gimp = comp("org.gimp.GIMP", "GNU Image Manipulation Program");
        gimp.bundle = "app/org.gimp.GIMP/x86_64/stable".into();
        gimp.runtime = "org.gnome.Platform/x86_64/51".into();
        gimp.categories = vec!["Graphics".into()];
        gimp.shots = vec![Shot {
            url: "https://x/a.png".into(),
            caption: String::new(),
        }];
        gimp.verified = true;
        let mut chrome = comp("com.google.Chrome", "Google Chrome");
        chrome.bundle = "app/com.google.Chrome/x86_64/stable".into();
        chrome.description = vec!["Fast".into()];
        let mut tiny = comp("org.example.Tiny", "Tiny");
        tiny.bundle = "app/org.example.Tiny/x86_64/stable".into();
        tiny.categories = vec!["Game".into()];

        let mut arch_gimp = comp("gimp", "GIMP");
        arch_gimp.package = "gimp".into();
        arch_gimp.aliases = vec!["org.gimp.GIMP".into()];
        arch_gimp.license = "GPL-3.0+".into();
        arch_gimp.desktop = "gimp.desktop".into();
        let mut acme = comp("acme", "Acme");
        acme.package = "plan9port".into();
        acme.icon_file = "plan9port_acme.jxl".into();
        acme.categories = vec!["Development".into()];
        let mut gone = comp("gone", "Gone");
        gone.package = "gone".into();

        let mut refs = HashMap::new();
        refs.insert(
            "app/org.gimp.GIMP/x86_64/stable".to_string(),
            RefInfo {
                version: "3.2.8".into(),
                download: 102_500_000,
                installed: 268_600_000,
                runtime: "org.gnome.Platform/x86_64/51".into(),
            },
        );
        refs.insert(
            "runtime/org.gnome.Platform/x86_64/51".to_string(),
            RefInfo {
                download: 432_800_000,
                installed: 1_100_000_000,
                ..Default::default()
            },
        );

        let mut packages = HashMap::new();
        packages.insert(
            "gimp".to_string(),
            ("extra".to_string(), "3.2.6-1".to_string()),
        );
        packages.insert(
            "plan9port".to_string(),
            ("extra".to_string(), "1-1".to_string()),
        );
        let mut arch_icons = HashMap::new();
        arch_icons.insert(
            ("extra".to_string(), "plan9port_acme.jxl".to_string()),
            "/cache/plan9port_acme.png".to_string(),
        );

        Inputs {
            flathub: vec![gimp, chrome, tiny],
            flathub_icons: String::new(),
            refs,
            arch: vec![
                (arch_gimp, "extra".into()),
                (acme, "extra".into()),
                (gone, "extra".into()),
            ],
            packages,
            arch_icons,
            featured: vec![
                ("create".into(), "org.gimp.GIMP".into()),
                ("create".into(), "nowhere".into()),
                ("play".into(), "org.example.Tiny".into()),
                ("popular".into(), "com.google.Chrome".into()),
                ("popular".into(), "org.gimp.GIMP".into()),
            ],
        }
    }

    #[test]
    fn the_same_app_under_another_id_by_its_name_and_package() {
        let mut i = inputs();
        let flathub = |id: &str, name: &str| {
            let mut c = comp(id, name);
            c.bundle = format!("app/{id}/x86_64/stable");
            c
        };
        i.flathub
            .push(flathub("com.bitwarden.desktop", "Bitwarden"));
        i.flathub.push(flathub("org.example.Notes", "Notes"));
        for (id, name, package) in [
            ("bitwarden.desktop", "Bitwarden", "bitwarden"),
            ("notes.desktop", "Notes", "sticky-notes"),
        ] {
            let mut c = comp(id, name);
            c.package = package.into();
            i.packages
                .insert(package.into(), ("extra".into(), "1-1".into()));
            i.arch.push((c, "extra".into()));
        }
        let apps = build(&i);
        let kinds = |id: &str| {
            let app = apps.iter().find(|a| a.meta.id == id).unwrap();
            app.sources.iter().map(Source::kind).collect::<Vec<_>>()
        };
        assert_eq!(kinds("com.bitwarden.desktop"), vec!["arch", "flathub"]);
        assert!(apps.iter().all(|a| a.meta.id != "bitwarden.desktop"));
        assert_eq!(kinds("org.example.Notes"), vec!["flathub"]);
        assert_eq!(kinds("notes.desktop"), vec!["arch"]);
        // Its desktop entry by its ID, which names one, where it says none.
        let notes = apps.iter().find(|a| a.meta.id == "notes.desktop").unwrap();
        assert!(
            matches!(&notes.sources[0], Source::Arch { desktop, .. } if desktop == "notes.desktop")
        );
    }

    #[test]
    fn one_app_from_each_place_it_comes_from_arch_first() {
        let apps = build(&inputs());
        let gimp = apps.iter().find(|a| a.meta.id == "org.gimp.GIMP").unwrap();
        assert_eq!(
            gimp.sources.iter().map(Source::kind).collect::<Vec<_>>(),
            vec!["arch", "flathub"]
        );
        assert_eq!(
            gimp.meta.name, "GNU Image Manipulation Program",
            "Flathub's words"
        );
        assert_eq!(
            gimp.meta.license, "GPL-3.0+",
            "what Flathub lacks, from Arch"
        );
        assert_eq!(gimp.category, "create");
        assert_eq!(gimp.featured, Some(("create".into(), 1)));
        assert_eq!(gimp.popular, Some(2), "in a category and in Popular");
        let chrome = apps
            .iter()
            .find(|a| a.meta.id == "com.google.Chrome")
            .unwrap();
        assert_eq!((chrome.popular, chrome.featured.clone()), (Some(1), None));
        assert_eq!(chrome.category, "internet", "Popular does not move an app");
        match &gimp.sources[1] {
            Source::Flathub {
                download,
                runtime,
                version,
                ..
            } => {
                assert_eq!(
                    (*download, runtime.as_str(), version.as_str()),
                    (102_500_000, "org.gnome.Platform/x86_64/51", "3.2.8")
                )
            }
            other => panic!("{other:?}"),
        }
        assert!(
            apps.iter().all(|a| a.meta.id != "gone"),
            "an Arch app no repository has now is left out"
        );
        let acme = apps.iter().find(|a| a.meta.id == "acme").unwrap();
        assert_eq!(
            (acme.icon.as_str(), acme.category),
            ("/cache/plan9port_acme.png", "develop")
        );
    }

    #[test]
    fn nova_builds_chrome_and_vs_code() {
        let apps = build(&inputs());
        let chrome = apps
            .iter()
            .find(|a| a.meta.id == "com.google.Chrome")
            .unwrap();
        assert_eq!(
            chrome.sources,
            vec![Source::Nova {
                package: "google-chrome".into(),
                maker: "Google".into()
            }]
        );
        assert_eq!(
            (
                chrome.meta.desktop.as_str(),
                chrome.meta.description[0].as_str()
            ),
            ("google-chrome.desktop", "Fast")
        );
        let code = apps
            .iter()
            .find(|a| a.meta.id == "com.visualstudio.code")
            .unwrap();
        assert_eq!(
            (code.meta.name.as_str(), code.category),
            ("Visual Studio Code", "develop")
        );
    }

    #[test]
    fn the_front_page_first_then_what_is_cared_for() {
        let apps = build(&inputs());
        let order: Vec<&str> = apps.iter().map(|a| a.meta.id.as_str()).collect();
        assert_eq!(order[0], "org.gimp.GIMP");
        assert_eq!(order[1], "org.example.Tiny");
        let tiny = &apps[1];
        assert_eq!(
            (tiny.featured.clone(), tiny.category),
            (Some(("play".into(), 1)), "play")
        );
        assert!(
            order.iter().position(|i| *i == "com.google.Chrome")
                < order.iter().position(|i| *i == "acme")
        );
    }

    #[test]
    fn writes_json() {
        let i = inputs();
        let apps = build(&i);
        let text = write(&apps, &i, 7);
        assert!(text.starts_with(r#"{"format":1,"built":7,"flathub":true,"arch":true,"runtimes":{"org.gnome.Platform/x86_64/51":{"download":432800000,"installed":1100000000}},"apps":["#));
        assert!(text.contains(r#""sources":[{"kind":"arch","package":"gimp","repo":"extra","version":"3.2.6-1","desktop":"gimp.desktop"},{"kind":"flathub","app":"org.gimp.GIMP","ref":"app/org.gimp.GIMP/x86_64/stable","version":"3.2.8","download":102500000,"installed":268600000,"runtime":"org.gnome.Platform/x86_64/51","verified":true}],"featured":"create","position":1,"popular":2"#));
    }

    #[test]
    fn reads_flatpak_pacman_and_the_front_page() {
        assert_eq!(parse_size("102.5\u{a0}MB"), 102_500_000);
        assert_eq!(parse_size("1.1 GB"), 1_100_000_000);
        assert_eq!(parse_size("344.1\u{a0}kB"), 344_100);
        assert_eq!(parse_size("512 bytes"), 512);
        assert_eq!(parse_size(""), 0);
        let refs = parse_refs("app/a/x86_64/stable\t1.0\t1.0\u{a0}MB\t2.0\u{a0}MB\torg.gnome.Platform/x86_64/51\nnoise\n");
        assert_eq!(refs["app/a/x86_64/stable"].installed, 2_000_000);
        assert_eq!(
            refs["app/a/x86_64/stable"].runtime,
            "org.gnome.Platform/x86_64/51"
        );
        let p = parse_packages("nova nova 1.0-1 [installed]\nextra gimp 3.2.6-1\ncore gimp 0-1\n");
        assert_eq!(p["gimp"], ("extra".to_string(), "3.2.6-1".to_string()));
        assert_eq!(
            parse_featured("# a list\ncreate org.gimp.GIMP # the best\n\nwork\n"),
            vec![("create".to_string(), "org.gimp.GIMP".to_string())]
        );
        assert_eq!(category_of(&["AudioVideo".into(), "Game".into()]), "play");
        assert_eq!(category_of(&["Utility".into()]), "utilities");
    }
}
