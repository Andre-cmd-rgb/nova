//! Where the catalogs are on this computer, and what pacman and flatpak say
//! of the packages and refs in them.
//!
//! Flathub's catalog is the one flatpak keeps for each installation that
//! has Flathub: the user's (where the App Store installs) and the system's,
//! the newer of the two. Arch's is archlinux-appstream-data's, in
//! /usr/share/swcatalog. pacman -Sl says what the release's repositories
//! have now, and flatpak remote-ls the size of each ref, from what flatpak
//! downloaded last: nothing here reaches the network.

use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::UNIX_EPOCH;

use crate::appstream;
use crate::catalog::{self, Inputs};

fn env_path(name: &str) -> Option<PathBuf> {
    std::env::var_os(name)
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
}

fn home() -> PathBuf {
    env_path("HOME").unwrap_or_else(|| PathBuf::from("/"))
}

pub fn nova_path() -> PathBuf {
    env_path("NOVA_PATH").unwrap_or_else(|| PathBuf::from("/usr/share/nova"))
}

pub fn cache_dir() -> PathBuf {
    if let Some(dir) = env_path("NOVA_APPS_CACHE") {
        return dir;
    }
    env_path("XDG_CACHE_HOME")
        .unwrap_or_else(|| home().join(".cache"))
        .join("nova/apps")
}

/// A flatpak installation: "user" or "system", and its folder.
pub struct Installation {
    pub scope: &'static str,
    pub root: PathBuf,
}

impl Installation {
    pub fn appstream(&self) -> PathBuf {
        self.root
            .join("appstream/flathub")
            .join(std::env::consts::ARCH)
            .join("active")
    }

    /// When flatpak last fetched Flathub's catalog for it.
    fn fetched(&self) -> Option<std::time::SystemTime> {
        let stamp = self
            .root
            .join("appstream/flathub")
            .join(std::env::consts::ARCH)
            .join(".timestamp");
        fs::metadata(&stamp).and_then(|m| m.modified()).ok()
    }
}

pub fn installations() -> Vec<Installation> {
    let user = env_path("FLATPAK_USER_DIR").unwrap_or_else(|| {
        env_path("XDG_DATA_HOME")
            .unwrap_or_else(|| home().join(".local/share"))
            .join("flatpak")
    });
    let system =
        env_path("FLATPAK_SYSTEM_DIR").unwrap_or_else(|| PathBuf::from("/var/lib/flatpak"));
    vec![
        Installation {
            scope: "user",
            root: user,
        },
        Installation {
            scope: "system",
            root: system,
        },
    ]
}

/// The installation whose Flathub catalog was fetched last.
pub fn flathub() -> Option<Installation> {
    installations()
        .into_iter()
        .filter(|i| i.appstream().join("appstream.xml").is_file())
        .max_by_key(|i| (i.fetched(), i.scope == "user"))
}

pub fn swcatalog() -> PathBuf {
    env_path("NOVA_APPS_SWCATALOG").unwrap_or_else(|| PathBuf::from("/usr/share/swcatalog"))
}

/// Arch's catalogs: (repository, file), core, extra and multilib.
pub fn arch_catalogs() -> Vec<(String, PathBuf)> {
    let dir = swcatalog().join("xml");
    let mut found = Vec::new();
    for repo in ["core", "extra", "multilib"] {
        for name in [format!("{repo}.xml.gz"), format!("{repo}.xml")] {
            let path = dir.join(&name);
            if path.is_file() {
                found.push((repo.to_string(), path));
                break;
            }
        }
    }
    found
}

fn sync_dir() -> PathBuf {
    env_path("NOVA_APPS_SYNC").unwrap_or_else(|| PathBuf::from("/var/lib/pacman/sync"))
}

fn featured_file() -> PathBuf {
    nova_path().join("apps/featured")
}

/// What the catalog is made from, each with what changes when it does: when
/// this differs from the one kept with the catalog, it is made again.
pub fn stamp() -> String {
    let mut lines = vec![format!("format {}", 1)];
    if let Some(i) = flathub() {
        let active = i.appstream();
        // A checkout's files all have the time 0: the commit it is names it.
        let commit = fs::read_link(&active)
            .map(|p| p.display().to_string())
            .unwrap_or_default();
        lines.push(format!("flathub {} {commit}", active.display()));
    }
    let mut file = |path: &Path| {
        let (time, size) = fs::metadata(path)
            .map(|m| {
                (
                    m.modified()
                        .ok()
                        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                        .map(|d| d.as_nanos())
                        .unwrap_or(0),
                    m.len(),
                )
            })
            .unwrap_or((0, 0));
        lines.push(format!("{} {time} {size}", path.display()));
    };
    for (_, path) in arch_catalogs() {
        file(&path);
    }
    if let Ok(entries) = fs::read_dir(sync_dir()) {
        let mut dbs: Vec<PathBuf> = entries
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| p.extension().is_some_and(|x| x == "db"))
            .collect();
        dbs.sort();
        for db in dbs {
            file(&db);
        }
    }
    file(&featured_file());
    lines.join("\n") + "\n"
}

fn read_text(path: &Path) -> Result<String, String> {
    let gz = path.extension().is_some_and(|x| x == "gz");
    if !gz {
        return fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()));
    }
    let mut child = Command::new("gzip")
        .args(["-dc", "--"])
        .arg(path)
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| format!("gzip: {e}"))?;
    let mut text = String::new();
    child
        .stdout
        .take()
        .expect("piped")
        .read_to_string(&mut text)
        .map_err(|e| format!("{}: {e}", path.display()))?;
    let status = child.wait().map_err(|e| format!("gzip: {e}"))?;
    if !status.success() {
        return Err(format!("{}: gzip could not read it", path.display()));
    }
    Ok(text)
}

/// A command's output, or "" when it cannot be run or fails.
fn output(program: &str, args: &[&str]) -> String {
    Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_default()
}

/// Arch's icons are JPEG XL, which Qt does not draw: each one an app needs
/// is made a PNG once, in the cache, by vipsthumbnail, a few at a time.
fn arch_icons(wanted: &[(String, String)], cache: &Path) -> HashMap<(String, String), String> {
    let mut found = HashMap::new();
    // What is to be made: from where, to where, and the icon it is.
    let mut todo: Vec<(PathBuf, PathBuf, (String, String))> = Vec::new();
    let icons = swcatalog().join("icons");
    for (repo, file) in wanted {
        let dest = cache
            .join("icons")
            .join(repo)
            .join(Path::new(file).with_extension("png"));
        if dest.is_file() {
            found.insert((repo.clone(), file.clone()), dest.display().to_string());
            continue;
        }
        let source = ["128x128", "64x64", "48x48"]
            .iter()
            .map(|s| {
                icons
                    .join(format!("archlinux-arch-{repo}"))
                    .join(s)
                    .join(file)
            })
            .find(|p| p.is_file());
        if let Some(source) = source {
            todo.push((source, dest, (repo.clone(), file.clone())));
        }
    }
    if !todo.is_empty() {
        let mut by_dir: HashMap<PathBuf, Vec<PathBuf>> = HashMap::new();
        for (source, dest, _) in &todo {
            let dir = dest.parent().expect("a file in a folder").to_path_buf();
            let _ = fs::create_dir_all(&dir);
            by_dir.entry(dir).or_default().push(source.clone());
        }
        let mut jobs = Vec::new();
        for (dir, sources) in by_dir {
            let chunk = sources.len().div_ceil(4).max(1);
            for part in sources.chunks(chunk) {
                // %s is the source's name without its extension.
                let mut cmd = Command::new("vipsthumbnail");
                cmd.args(["-s", "128", "-o"])
                    .arg(format!("{}/%s.png", dir.display()))
                    .args(part);
                cmd.stdin(Stdio::null())
                    .stdout(Stdio::null())
                    .stderr(Stdio::null());
                if let Ok(child) = cmd.spawn() {
                    jobs.push(child);
                }
            }
        }
        for mut job in jobs {
            let _ = job.wait();
        }
        for (_, dest, key) in todo {
            if dest.is_file() {
                found.insert(key, dest.display().to_string());
            }
        }
    }
    found
}

pub fn gather() -> Result<Inputs, String> {
    let mut inputs = Inputs {
        flathub: Vec::new(),
        flathub_icons: String::new(),
        refs: HashMap::new(),
        arch: Vec::new(),
        packages: HashMap::new(),
        arch_icons: HashMap::new(),
        featured: Vec::new(),
    };
    if let Some(i) = flathub() {
        let dir = i.appstream();
        let text = read_text(&dir.join("appstream.xml"))?;
        inputs.flathub = appstream::parse(&text).map_err(|e| format!("Flathub's catalog: {e}"))?;
        inputs.flathub_icons = dir.join("icons").display().to_string();
        let flag = format!("--{}", i.scope);
        inputs.refs = catalog::parse_refs(&output(
            "flatpak",
            &[
                "remote-ls",
                &flag,
                "--cached",
                "flathub",
                "--columns=ref,version,download-size,installed-size,runtime",
            ],
        ));
    }
    let catalogs = arch_catalogs();
    if !catalogs.is_empty() {
        inputs.packages = catalog::parse_packages(&output("pacman", &["-Sl"]));
    }
    for (repo, path) in catalogs {
        let text = read_text(&path)?;
        let comps = appstream::parse(&text).map_err(|e| format!("Arch's {repo} catalog: {e}"))?;
        inputs
            .arch
            .extend(comps.into_iter().map(|c| (c, repo.clone())));
    }
    // The icons of the Arch apps Flathub has no icon of.
    let on_flathub: HashSet<String> = inputs.flathub.iter().flat_map(catalog::keys).collect();
    let wanted: Vec<(String, String)> = inputs
        .arch
        .iter()
        .filter(|(c, _)| !c.icon_file.is_empty() && inputs.packages.contains_key(&c.package))
        .filter(|(c, _)| !catalog::keys(c).iter().any(|k| on_flathub.contains(k)))
        .map(|(c, repo)| (repo.clone(), c.icon_file.clone()))
        .collect();
    inputs.arch_icons = arch_icons(&wanted, &cache_dir());
    inputs.featured =
        catalog::parse_featured(&fs::read_to_string(featured_file()).unwrap_or_default());
    Ok(inputs)
}
