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

use std::collections::{HashMap, HashSet};

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
        /// What its recipe installs with it (src/apps/data/recipes) that the
        /// release's repositories have, which the app's page names and counts
        /// in its size: what nova-apps-apply installs with it.
        with: Vec<String>,
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

    /// Its place among an app's sources: Nova's build, then Arch's, then
    /// Flathub's, or Flathub's before Arch's for an app whose recipe prefers
    /// it.
    fn order(&self, flathub_first: bool) -> u8 {
        match self {
            Source::Nova { .. } => 0,
            Source::Arch { .. } => 1 + u8::from(flathub_first),
            Source::Flathub { .. } => 2 - u8::from(flathub_first),
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

/// What a Flathub ref comes to: its download and size installed, and the
/// runtime it needs.
#[derive(Debug, Default, Clone, PartialEq)]
pub struct RefInfo {
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
    /// What the recipes say of Arch's packages.
    pub recipes: Recipes,
}

/// What the recipes (src/apps/data/recipes) say that the catalog shows: the
/// Arch packages offered from Flathub first, and what each installs with it.
/// nova-apps-apply reads the same file, as root, for what it installs.
#[derive(Debug, Default, Clone, PartialEq)]
pub struct Recipes {
    pub prefer_flathub: HashSet<String>,
    pub with: HashMap<String, Vec<String>>,
}

/// A package's name as the recipes may give one: what pacman takes, never an
/// option.
fn package_name(word: &str) -> bool {
    let mut chars = word.chars();
    chars
        .next()
        .is_some_and(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || "@_+".contains(c))
        && chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || "@._+-".contains(c))
}

/// The recipes: "<package> <directive> <operand>..." lines, # starting a
/// comment. Only prefer and with are the catalog's; a line it cannot read is
/// passed over, as nova-apps-apply refuses one.
pub fn parse_recipes(text: &str) -> Recipes {
    let mut recipes = Recipes::default();
    for line in text.lines() {
        let words: Vec<&str> = line
            .split('#')
            .next()
            .unwrap_or("")
            .split_whitespace()
            .collect();
        match words.as_slice() {
            [package, "prefer", "flathub"] if package_name(package) => {
                recipes.prefer_flathub.insert(package.to_string());
            }
            [package, "prefer", "arch"] if package_name(package) => {
                recipes.prefer_flathub.remove(*package);
            }
            [package, "with", extras @ ..]
                if package_name(package)
                    && !extras.is_empty()
                    && extras.iter().all(|w| package_name(w)) =>
            {
                let list = recipes.with.entry(package.to_string()).or_default();
                for extra in extras {
                    if !list.iter().any(|e| e == extra) {
                        list.push(extra.to_string());
                    }
                }
            }
            _ => {}
        }
    }
    recipes
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
        // An app's ref, which flatpak and the install script are handed as
        // it is: nothing that reads as an option, nor a runtime.
        if !c.bundle.starts_with("app/") || find(&by_id, c).is_some() {
            continue;
        }
        let info = inputs.refs.get(&c.bundle).cloned().unwrap_or_default();
        let app_id = c.bundle.split('/').nth(1).unwrap_or(&c.id).to_string();
        let source = Source::Flathub {
            app: app_id,
            reference: c.bundle.clone(),
            version: c.version.clone(),
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
            // What will really go in with it: nova-apps-apply leaves out an
            // extra the release's repositories lack (pacman -Si), and so the
            // page names and nova-apps-size counts only the others.
            with: inputs
                .recipes
                .with
                .get(&c.package)
                .map(|with| {
                    with.iter()
                        .filter(|p| inputs.packages.contains_key(*p))
                        .cloned()
                        .collect()
                })
                .unwrap_or_default(),
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
        let flathub_first = app.sources.iter().any(
            |s| matches!(s, Source::Arch { package, .. } if inputs.recipes.prefer_flathub.contains(package)),
        );
        app.sources.sort_by_key(|s| s.order(flathub_first));
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
            with,
        } => {
            o.str("package", package)
                .str("repo", repo)
                .some("version", version)
                .some("desktop", desktop);
            if !with.is_empty() {
                o.strs("with", with);
            }
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

/// A source as the list has it: only what tells where an app is installed
/// from and how it is opened, none of the versions and sizes the app's page
/// has.
fn write_brief_source(out: &mut String, s: &Source) {
    let mut o = Object::new(out);
    o.str("kind", s.kind());
    match s {
        Source::Nova { package, .. } => {
            o.str("package", package);
        }
        Source::Arch {
            package,
            desktop,
            with,
            ..
        } => {
            o.str("package", package).some("desktop", desktop);
            if !with.is_empty() {
                o.strs("with", with);
            }
        }
        Source::Flathub { app, .. } => {
            o.str("app", app);
        }
    }
    o.end();
}

/// An app as the list has it: what the lists, the search, the status and
/// Open need, and the name of its page file. The window holds all of them
/// while it is open, so the description, the pictures and the rest stay in
/// the page.
pub fn write_brief(out: &mut String, app: &App, page: &str) {
    let m = &app.meta;
    let mut o = Object::new(out);
    o.str("id", &m.id)
        .str("name", &m.name)
        .some("summary", &m.summary);
    o.str("category", app.category);
    o.some("icon", &app.icon)
        .some("iconName", &m.icon_name)
        .some("desktop", &m.desktop);
    if !m.keywords.is_empty() {
        o.str("keywords", &m.keywords.join(" "));
    }
    o.raw("sources", |out| {
        out.push('[');
        for (i, s) in app.sources.iter().enumerate() {
            if i > 0 {
                out.push(',');
            }
            write_brief_source(out, s);
        }
        out.push(']');
    });
    if let Some((cat, n)) = &app.featured {
        o.str("featured", cat).num("position", *n as u64);
    }
    if let Some(n) = app.popular {
        o.num("popular", n as u64);
    }
    o.num("rank", app.rank).str("page", page);
    o.end();
}

/// The name of an app's page file: its ID with every byte outside
/// [A-Za-z0-9.-] written as _ and two hex digits (the underscore too, so
/// that two IDs never share a name), and a leading dot the same, so that no
/// ID gives "." or ".." or a hidden file.
pub fn page_name(id: &str) -> String {
    let mut name = String::with_capacity(id.len() + 5);
    for (i, b) in id.bytes().enumerate() {
        if b.is_ascii_alphanumeric() || b == b'-' || (b == b'.' && i > 0) {
            name.push(b as char);
        } else {
            name.push_str(&format!("_{b:02X}"));
        }
    }
    name.push_str(".json");
    name
}

/// An app's page: its whole entry, and the runtimes its Flathub source needs,
/// so that the page can tell what an install comes to without the catalog's
/// table of every runtime.
pub fn write_page(app: &App, inputs: &Inputs) -> String {
    let mut out = String::with_capacity(2048);
    let mut o = Object::new(&mut out);
    write_fields(&mut o, app);
    o.raw("runtimes", |out| {
        let mut r = Object::new(out);
        for s in &app.sources {
            if let Source::Flathub { runtime, .. } = s {
                if let Some(info) = inputs.refs.get(&format!("runtime/{runtime}")) {
                    r.raw(runtime, |out| write_runtime(out, info));
                }
            }
        }
        r.end();
    });
    o.end();
    out.push('\n');
    out
}

fn write_runtime(out: &mut String, info: &RefInfo) {
    Object::new(out)
        .num("download", info.download)
        .num("installed", info.installed)
        .end();
}

/// The list the window reads: what the catalog says of itself, the folder of
/// the pages, and each app in brief with the name of its page.
pub fn write_list(apps: &[App], inputs: &Inputs, built: u64, pages: &str) -> String {
    let mut out = String::with_capacity(apps.len() * 500);
    let mut o = Object::new(&mut out);
    o.num("format", 1).num("built", built);
    o.bool("flathub", !inputs.flathub.is_empty())
        .bool("arch", !inputs.arch.is_empty());
    o.str("pages", pages);
    o.raw("apps", |out| {
        out.push('[');
        for (i, app) in apps.iter().enumerate() {
            if i > 0 {
                out.push_str(",\n");
            }
            write_brief(out, app, &page_name(&app.meta.id));
        }
        out.push(']');
    });
    o.end();
    out.push('\n');
    out
}

pub fn write_app(out: &mut String, app: &App) {
    let mut o = Object::new(out);
    write_fields(&mut o, app);
    o.end();
}

fn write_fields(o: &mut Object, app: &App) {
    let m = &app.meta;
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
            r.raw(name, |out| write_runtime(out, info));
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

/// `flatpak remote-ls --columns=ref,download-size,installed-size,runtime`,
/// a ref to a line.
pub fn parse_refs(text: &str) -> HashMap<String, RefInfo> {
    let mut refs = HashMap::new();
    for line in text.lines() {
        let f: Vec<&str> = line.split('\t').collect();
        if f.len() < 3 || !(f[0].starts_with("app/") || f[0].starts_with("runtime/")) {
            continue;
        }
        refs.insert(
            f[0].to_string(),
            RefInfo {
                download: parse_size(f[1]),
                installed: parse_size(f[2]),
                runtime: f.get(3).map(|r| r.trim().to_string()).unwrap_or_default(),
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
        gimp.version = "3.2.8".into();
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
            recipes: Recipes::default(),
        }
    }

    #[test]
    fn recipes_say_what_comes_with_an_app_and_where_it_is_offered_from() {
        let r = parse_recipes(
            "# a comment\n\
             vlc with vlc-plugins-all   # why\n\
             vlc with vlc-plugins-all extra-one\n\
             vlc skip vlc-gui-ncurses\n\
             discord prefer flathub\n\
             zed prefer flathub\n\
             zed prefer arch\n\
             bad with --overwrite=*\n\
             Bad with x\n\
             lonely with\n\
             virt-manager after enable-socket libvirtd.socket\n",
        );
        assert_eq!(r.with["vlc"], vec!["vlc-plugins-all", "extra-one"]);
        assert!(!r.with.contains_key("bad"));
        assert!(!r.with.contains_key("Bad"));
        assert!(!r.with.contains_key("lonely"));
        assert!(r.prefer_flathub.contains("discord"));
        assert!(!r.prefer_flathub.contains("zed"));
        assert_eq!(r.with.len(), 1);
    }

    #[test]
    fn a_recipe_puts_flathub_first_and_names_what_arch_installs_with_it() {
        let mut i = inputs();
        // gimp-gone is not in the release's repositories: nova-apps-apply
        // leaves it out, so the page neither names nor sizes it.
        i.recipes = parse_recipes("gimp prefer flathub\ngimp with gimp-help gimp-gone\n");
        i.packages.insert(
            "gimp-help".to_string(),
            ("extra".to_string(), "3.0-1".to_string()),
        );
        let apps = build(&i);
        let gimp = apps.iter().find(|a| a.meta.id == "org.gimp.GIMP").unwrap();
        assert_eq!(gimp.sources[0].kind(), "flathub");
        assert_eq!(gimp.sources[1].kind(), "arch");
        assert!(
            matches!(&gimp.sources[1], Source::Arch { with, .. } if with == &vec!["gimp-help".to_string()])
        );
        let mut brief = String::new();
        write_brief(&mut brief, gimp, "p.json");
        assert!(
            brief.contains(
                r#""kind":"arch","package":"gimp","desktop":"gimp.desktop","with":["gimp-help"]"#
            ),
            "{brief}"
        );
        // Without the recipe, Arch's first, and no with.
        let apps = build(&inputs());
        let gimp = apps.iter().find(|a| a.meta.id == "org.gimp.GIMP").unwrap();
        assert_eq!(gimp.sources[0].kind(), "arch");
        let mut brief = String::new();
        write_brief(&mut brief, gimp, "p.json");
        assert!(!brief.contains("with"));
    }

    #[test]
    fn the_shipped_recipes_read_as_they_are_written() {
        let text = include_str!("../data/recipes");
        let r = parse_recipes(text);
        // Every with line the catalog reads; a line it passed over would be
        // one nova-apps-apply refuses too.
        let with_lines = text
            .lines()
            .filter(|l| l.split('#').next().unwrap_or("").split_whitespace().nth(1) == Some("with"))
            .count();
        assert!(with_lines > 0);
        let read: usize = text
            .lines()
            .filter_map(|l| {
                let w: Vec<&str> = l
                    .split('#')
                    .next()
                    .unwrap_or("")
                    .split_whitespace()
                    .collect();
                (w.get(1) == Some(&"with")).then(|| w.len() - 2)
            })
            .sum();
        assert_eq!(r.with.values().map(Vec::len).sum::<usize>(), read);
        assert!(r.prefer_flathub.contains("discord"));
    }

    #[test]
    fn only_a_flathub_app_ref_is_offered() {
        let mut i = inputs();
        for (id, bundle) in [
            ("org.bad.Ext", "runtime/org.bad.Ext/x86_64/1"),
            ("org.bad.Opt", "--user"),
        ] {
            let mut c = comp(id, id);
            c.bundle = bundle.into();
            i.flathub.push(c);
        }
        let apps = build(&i);
        assert!(!apps.iter().any(|a| a.meta.id.starts_with("org.bad.")));
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
    fn the_list_has_what_lists_need_and_the_name_of_the_page() {
        let i = inputs();
        let apps = build(&i);
        let text = write_list(&apps, &i, 7, "/cache/pages");
        assert!(text.starts_with(
            r#"{"format":1,"built":7,"flathub":true,"arch":true,"pages":"/cache/pages","apps":["#
        ));
        assert!(text.contains(r#""sources":[{"kind":"arch","package":"gimp","desktop":"gimp.desktop"},{"kind":"flathub","app":"org.gimp.GIMP"}],"featured":"create","position":1,"popular":2,"rank":"#));
        assert!(text.contains(r#""page":"org.gimp.GIMP.json""#));
        for left_out in [
            "description",
            "shots",
            "license",
            "version",
            "runtimes",
            "download",
            "verified",
            "developer",
        ] {
            assert!(!text.contains(left_out), "{left_out} is in the list");
        }
        // Chrome has a description; the list does not.
        assert!(!text.contains("Fast"));
        assert!(text.len() < write(&apps, &i, 7).len());
    }

    #[test]
    fn a_page_has_the_whole_entry_and_the_runtime_its_source_needs() {
        let mut i = inputs();
        i.refs.insert(
            "runtime/org.other.Platform/x86_64/1".to_string(),
            RefInfo {
                download: 1,
                installed: 2,
                ..Default::default()
            },
        );
        let apps = build(&i);
        let gimp = apps.iter().find(|a| a.meta.id == "org.gimp.GIMP").unwrap();
        let text = write_page(gimp, &i);
        let mut whole = String::new();
        write_app(&mut whole, gimp);
        assert!(text.starts_with(&whole[..whole.len() - 1]));
        assert!(text.contains(r#""shots":[{"url":"https://x/a.png"}]"#));
        assert!(text.contains(r#""version":"3.2.8","download":102500000"#));
        assert!(text.ends_with(
            "\"runtimes\":{\"org.gnome.Platform/x86_64/51\":{\"download\":432800000,\"installed\":1100000000}}}\n"
        ));
        // An app that is not from Flathub has no runtime.
        let acme = apps.iter().find(|a| a.meta.id == "acme").unwrap();
        assert!(write_page(acme, &i).ends_with("\"runtimes\":{}}\n"));
    }

    #[test]
    fn a_page_file_name_is_safe_for_any_id() {
        assert_eq!(page_name("org.gimp.GIMP"), "org.gimp.GIMP.json");
        assert_eq!(page_name("a-b"), "a-b.json");
        assert_eq!(page_name("a/b c"), "a_2Fb_20c.json");
        assert_eq!(page_name("../etc"), "_2E._2Fetc.json");
        assert_eq!(page_name("."), "_2E.json");
        assert_eq!(page_name("é"), "_C3_A9.json");
        // The underscore is escaped too, so that these two differ.
        assert_ne!(page_name("a_41"), page_name("aA"));
        assert_eq!(page_name("a_41"), "a_5F41.json");
        for id in ["a/../b", "\0x", "x\n", "..", "a\\b", "", ".hidden"] {
            let n = page_name(id);
            assert!(n
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b)));
            assert!(!n.starts_with('.') || id.is_empty());
        }
    }

    #[test]
    fn reads_flatpak_pacman_and_the_front_page() {
        assert_eq!(parse_size("102.5\u{a0}MB"), 102_500_000);
        assert_eq!(parse_size("1.1 GB"), 1_100_000_000);
        assert_eq!(parse_size("344.1\u{a0}kB"), 344_100);
        assert_eq!(parse_size("512 bytes"), 512);
        assert_eq!(parse_size(""), 0);
        let refs = parse_refs(
            "app/a/x86_64/stable\t1.0\u{a0}MB\t2.0\u{a0}MB\torg.gnome.Platform/x86_64/51\nnoise\n",
        );
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
