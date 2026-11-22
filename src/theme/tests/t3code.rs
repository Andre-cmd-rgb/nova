//! T3 Code's theme, end to end, for every theme Nova ships: nova-theme renders
//! it from the repository's palettes and template into a scratch home, and
//! the real nova-theme-apply hands it to a scratch T3 Code home. Whatever
//! appearance T3 Code shows must be Nova's colors (both appearances present,
//! the same palette, every role T3 Code knows filled, each a #rrggbb), and
//! the text must read on what it is drawn on.

use std::collections::BTreeSet;
use std::fs;
use std::os::unix::fs::{symlink, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicUsize, Ordering};

const REPO: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../..");

/// The roles T3 Code 0.1.11 colors its window with: a role left out of a
/// variant is drawn in T3 Code's stock color.
const ROLES: [&str; 61] = [
    "canvas",
    "chrome",
    "toolbar",
    "toolbarForeground",
    "toolbarBorder",
    "toolbarControl",
    "toolbarControlForeground",
    "toolbarControlHover",
    "surface",
    "surfaceRaised",
    "surfaceOverlay",
    "text",
    "textMuted",
    "border",
    "input",
    "focus",
    "accent",
    "accentForeground",
    "secondary",
    "secondaryForeground",
    "muted",
    "mutedForeground",
    "placeholder",
    "secondaryLabel",
    "iconMuted",
    "error",
    "errorForeground",
    "errorSurface",
    "warning",
    "warningForeground",
    "warningSurface",
    "update",
    "updateForeground",
    "updateSurface",
    "accentSurface",
    "accentSurfaceForeground",
    "messageSurface",
    "messageForeground",
    "messageAction",
    "messageActionForeground",
    "messageActionHover",
    "codeBackground",
    "codeForeground",
    "searchMatchBackground",
    "searchMatchForeground",
    "searchMatchActiveBackground",
    "searchMatchActiveForeground",
    "sidebar",
    "sidebarForeground",
    "sidebarMutedForeground",
    "sidebarControlSurface",
    "sidebarRowHover",
    "sidebarRowActive",
    "sidebarRowSelected",
    "sidebarBorder",
    "terminalBackground",
    "terminalForeground",
    "terminalCursor",
    "terminalSelection",
    "terminalScrollbar",
    "terminalScrollbarHover",
];

/// WCAG's floors: 4.5:1 for text, 3:1 for what is not text but must be seen
/// (an icon, a focus ring, the cursor).
const TEXT: f64 = 4.5;
const SEEN: f64 = 3.0;

/// Each foreground role, the roles it is drawn on, and its floor.
const PAIRS: &[(&str, &[&str], f64)] = &[
    (
        "text",
        &[
            "canvas",
            "chrome",
            "surface",
            "surfaceRaised",
            "surfaceOverlay",
            "secondary",
            "muted",
            "toolbarControl",
            "toolbarControlHover",
        ],
        TEXT,
    ),
    (
        "textMuted",
        &[
            "canvas",
            "surface",
            "surfaceRaised",
            "surfaceOverlay",
            "muted",
        ],
        TEXT,
    ),
    ("toolbarForeground", &["toolbar"], TEXT),
    (
        "toolbarControlForeground",
        &["toolbarControl", "toolbarControlHover"],
        TEXT,
    ),
    ("secondaryForeground", &["secondary"], TEXT),
    ("mutedForeground", &["muted", "canvas", "surface"], TEXT),
    ("placeholder", &["canvas", "surface", "surfaceRaised"], TEXT),
    ("secondaryLabel", &["canvas", "surface"], TEXT),
    ("iconMuted", &["canvas", "surface"], SEEN),
    ("accentForeground", &["accent"], TEXT),
    ("accentSurfaceForeground", &["accentSurface"], TEXT),
    ("messageForeground", &["messageSurface"], TEXT),
    (
        "messageActionForeground",
        &["messageAction", "messageActionHover"],
        TEXT,
    ),
    ("errorForeground", &["errorSurface", "canvas"], TEXT),
    ("warningForeground", &["warningSurface", "canvas"], TEXT),
    ("updateForeground", &["updateSurface", "canvas"], TEXT),
    ("error", &["canvas"], SEEN),
    ("warning", &["canvas"], SEEN),
    ("update", &["canvas"], SEEN),
    ("focus", &["canvas", "surface"], SEEN),
    ("codeForeground", &["codeBackground"], TEXT),
    ("searchMatchForeground", &["searchMatchBackground"], TEXT),
    (
        "searchMatchActiveForeground",
        &["searchMatchActiveBackground"],
        TEXT,
    ),
    (
        "sidebarForeground",
        &[
            "sidebar",
            "sidebarRowHover",
            "sidebarRowActive",
            "sidebarRowSelected",
            "sidebarControlSurface",
        ],
        TEXT,
    ),
    (
        "sidebarMutedForeground",
        &["sidebar", "sidebarRowHover"],
        TEXT,
    ),
    (
        "terminalForeground",
        &["terminalBackground", "terminalSelection"],
        TEXT,
    ),
    ("terminalCursor", &["terminalBackground"], SEEN),
];

struct Sandbox {
    root: PathBuf,
}

impl Sandbox {
    fn new() -> Sandbox {
        static COUNTER: AtomicUsize = AtomicUsize::new(0);
        let root = std::env::temp_dir().join(format!(
            "nova-t3code-test.{}.{}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = fs::remove_dir_all(&root);
        for (from, to) in [
            ("theme/palettes", "share/themes"),
            ("theme/templates", "share/templates"),
            ("theme/wordmark", "share/wordmark"),
        ] {
            copy_dir(&Path::new(REPO).join(from), &root.join(to));
        }
        let bin = root.join("bin");
        fs::create_dir_all(&bin).unwrap();
        for stub in ["nova-shell", "nova-theme-apply", "nova-hook"] {
            write_script(&bin.join(stub), "#!/bin/sh\nexit 0\n");
        }
        // The tests' photos are PPMs already, handed on as they are.
        write_script(
            &bin.join("vipsthumbnail"),
            "#!/bin/sh\nimage=$1\nwhile [ $# -gt 1 ]; do shift; done\ncp \"$image\" \"$1\"\n",
        );
        // The real nova-theme-apply, which asks nova-theme for the mode.
        let apply = root.join("apply");
        fs::create_dir_all(&apply).unwrap();
        symlink(env!("CARGO_BIN_EXE_nova-theme"), apply.join("nova-theme")).unwrap();
        fs::create_dir_all(root.join("home/.config/nova/backgrounds")).unwrap();
        fs::create_dir_all(root.join("home/.t3/userdata")).unwrap();
        fs::create_dir_all(root.join("run")).unwrap();
        Sandbox { root }
    }

    fn command(&self, program: &Path, path: &Path) -> Command {
        let mut command = Command::new(program);
        command
            .env_clear()
            .env("PATH", format!("{}:/usr/bin:/bin", path.display()))
            .env("HOME", self.root.join("home"))
            .env("NOVA_PATH", self.root.join("share"))
            .env("XDG_RUNTIME_DIR", self.root.join("run"))
            .env("DBUS_SESSION_BUS_ADDRESS", "unix:path=/nonexistent");
        command
    }

    fn theme(&self, args: &[&str]) {
        let out = self
            .command(
                Path::new(env!("CARGO_BIN_EXE_nova-theme")),
                &self.root.join("bin"),
            )
            .args(args)
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "nova-theme {args:?}: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    }

    /// nova-theme-apply t3code, then the theme file T3 Code reads.
    fn t3code(&self) -> PathBuf {
        let apply = Path::new(REPO).join("src/cli/bin/nova-theme-apply");
        let out = self
            .command(&apply, &self.root.join("apply"))
            .arg("t3code")
            .output()
            .unwrap();
        assert!(
            out.status.success() && out.stderr.is_empty(),
            "nova-theme-apply t3code: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        self.root.join("home/.t3/userdata/themes/nova.json")
    }

    fn settings(&self) -> PathBuf {
        self.root.join("home/.t3/userdata/settings.json")
    }

    fn photo(&self, name: &str, top: [u8; 3], rest: [u8; 3]) -> String {
        let mut bytes = b"P6\n64 36\n255\n".to_vec();
        for row in 0..36 {
            for _ in 0..64 {
                bytes.extend_from_slice(if row < 5 { &top } else { &rest });
            }
        }
        let path = self.root.join("home/.config/nova/backgrounds").join(name);
        fs::write(&path, bytes).unwrap();
        path.to_str().unwrap().to_owned()
    }
}

impl Drop for Sandbox {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn write_script(path: &Path, body: &str) {
    fs::write(path, body).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
}

fn copy_dir(from: &Path, to: &Path) {
    fs::create_dir_all(to).unwrap();
    for entry in fs::read_dir(from).unwrap() {
        let entry = entry.unwrap();
        let target = to.join(entry.file_name());
        if entry.file_type().unwrap().is_dir() {
            copy_dir(&entry.path(), &target);
        } else {
            fs::copy(entry.path(), &target).unwrap();
        }
    }
}

/// jq -r <filter> <file>, as nova-theme-apply has jq too.
fn jq(file: &Path, filter: &str) -> String {
    let out = Command::new("jq")
        .arg("-r")
        .arg(filter)
        .arg(file)
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "jq {filter} {}: {}",
        file.display(),
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8(out.stdout).unwrap().trim_end().to_owned()
}

fn hex(value: &str) -> Option<[u8; 3]> {
    let digits = value.strip_prefix('#').filter(|d| d.len() == 6)?;
    let channel = |i: usize| u8::from_str_radix(digits.get(i..i + 2)?, 16).ok();
    Some([channel(0)?, channel(2)?, channel(4)?])
}

/// WCAG 2's contrast ratio, worked out here apart from the engine's own.
fn contrast(a: [u8; 3], b: [u8; 3]) -> f64 {
    let luminance = |c: [u8; 3]| {
        let linear = |v: u8| {
            let v = f64::from(v) / 255.0;
            if v <= 0.04045 {
                v / 12.92
            } else {
                ((v + 0.055) / 1.055).powf(2.4)
            }
        };
        0.2126 * linear(c[0]) + 0.7152 * linear(c[1]) + 0.0722 * linear(c[2])
    };
    let (x, y) = (luminance(a), luminance(b));
    (x.max(y) + 0.05) / (x.min(y) + 0.05)
}

/// Checks one theme's file; returns the contrast of each pair, and the
/// failures, as lines.
fn check(name: &str, theme: &Path) -> (Vec<String>, Vec<String>) {
    let mut failures = Vec::new();
    let mut table = Vec::new();
    let appearance = jq(theme, ".appearance");
    let other = match appearance.as_str() {
        "light" => "dark",
        "dark" => "light",
        _ => {
            failures.push(format!("{name}: appearance is {appearance:?}"));
            return (table, failures);
        }
    };
    for key in ["canvas", "accent"] {
        if hex(&jq(theme, &format!(".{key}"))).is_none() {
            failures.push(format!("{name}: {key} is not #rrggbb"));
        }
    }
    let variants = jq(theme, "(.variants // {}) | keys | join(\" \")");
    if variants != other {
        failures.push(format!("{name}: variants are [{variants}], not [{other}]"));
    }
    if jq(theme, &format!(".variants.{other} == .colors")) != "true" {
        failures.push(format!(
            "{name}: the {other} variant is not the {appearance} palette"
        ));
    }
    let colors: Vec<(String, String)> =
        jq(theme, ".colors | to_entries[] | \"\\(.key)\\t\\(.value)\"")
            .lines()
            .filter_map(|line| line.split_once('\t'))
            .map(|(k, v)| (k.to_owned(), v.to_owned()))
            .collect();
    let roles: BTreeSet<&str> = ROLES.into_iter().collect();
    let filled: BTreeSet<&str> = colors.iter().map(|(k, _)| k.as_str()).collect();
    if filled != roles {
        failures.push(format!(
            "{name}: roles differ from T3 Code's: {:?}",
            filled.symmetric_difference(&roles).collect::<Vec<_>>()
        ));
    }
    let color = |role: &str| {
        colors
            .iter()
            .find(|(k, _)| k == role)
            .and_then(|(_, v)| hex(v))
    };
    for role in ROLES {
        if color(role).is_none() {
            failures.push(format!("{name}: {role} is not #rrggbb"));
        }
    }
    for (fg, bgs, floor) in PAIRS {
        for bg in *bgs {
            let (Some(a), Some(b)) = (color(fg), color(bg)) else {
                continue;
            };
            let ratio = contrast(a, b);
            table.push(format!(
                "{name:<20} {fg:>27} on {bg:<27} {ratio:5.2} (≥ {floor})"
            ));
            if ratio < *floor {
                failures.push(format!(
                    "{name}: {fg} on {bg} is {ratio:.2}:1, under {floor}:1"
                ));
            }
        }
    }
    (table, failures)
}

#[test]
fn t3_code_shows_every_theme_in_both_appearances_and_its_text_reads() {
    let mut table = Vec::new();
    let mut failures = Vec::new();
    let mut checked = 0;
    let mut record = |name: &str, s: &Sandbox| {
        let theme = s.t3code();
        let (lines, failed) = check(name, &theme);
        table.extend(lines);
        failures.extend(failed);
        checked += 1;
    };

    let s = Sandbox::new();
    let mut names: Vec<String> = fs::read_dir(Path::new(REPO).join("theme/palettes"))
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    assert_eq!(names.len(), 12, "{names:?}");
    for name in &names {
        s.theme(&["set", name]);
        record(name, &s);
    }
    // The adaptive theme as photos make it, dark and light, and held to the
    // other on each.
    let dusk = s.photo("dusk.png", [0xd0, 0x80, 0xb0], [0x20, 0x30, 0x60]);
    let paper = s.photo("paper.png", [0xf2, 0xee, 0xe2], [0xf2, 0xee, 0xe2]);
    s.theme(&["set", "adaptive"]);
    s.theme(&["bg", "set", &dusk]);
    record("adaptive dusk", &s);
    s.theme(&["bg", "set", &paper]);
    record("adaptive paper", &s);
    s.theme(&["adaptive", "dark"]);
    record("adaptive paper dark", &s);
    s.theme(&["adaptive", "light"]);
    s.theme(&["bg", "set", &dusk]);
    record("adaptive dusk light", &s);

    println!("{}", table.join("\n"));
    assert_eq!(checked, 16);
    assert!(failures.is_empty(), "\n{}", failures.join("\n"));
}

#[test]
fn t3_code_is_told_once_to_follow_the_desktops_light_or_dark() {
    let s = Sandbox::new();
    s.theme(&["set", "nord"]);
    s.t3code();
    let settings = s.settings();
    assert_eq!(
        jq(
            &settings,
            "[.defaultTheme, .defaultAppearance] | join(\" \")"
        ),
        "nova system"
    );
    let stamp = jq(&settings, ".defaultAppearanceSetAt");
    assert!(stamp.len() == 24 && stamp.ends_with('Z'), "{stamp}");
    // A theme change later keeps the stamp, so no window applies it again.
    s.theme(&["set", "rose-pine"]);
    assert_eq!(jq(&s.t3code(), ".appearance"), "light");
    assert_eq!(jq(&settings, ".defaultAppearanceSetAt"), stamp);
}

/// Every role T3 Code knows, read from the installed app, is one Nova fills,
/// and Nova fills none it does not know. Without T3 Code installed there is
/// nothing to compare with. Not in the default run: what it reads is the
/// machine's T3 Code, not the tree, so CI (none installed) would pass it by
/// and a developer's T3 Code update would fail a change that did nothing
/// wrong. Run it after T3 Code updates:
/// `cargo test -p nova-theme --test t3code -- --ignored`.
#[test]
#[ignore = "compares with the T3 Code installed on this machine; run with --ignored"]
fn the_roles_are_the_installed_t3_codes() {
    let Some(asar) = [
        "/opt/t3code-bin/resources/app.asar",
        "/opt/t3code/resources/app.asar",
        "/usr/lib/t3code/resources/app.asar",
    ]
    .into_iter()
    .map(Path::new)
    .find(|p| p.is_file()) else {
        eprintln!("T3 Code is not installed here; its roles are not compared");
        return;
    };
    let bytes = fs::read(asar).unwrap();
    let marker = b"canvas.chrome.toolbar.";
    let start = bytes
        .windows(marker.len())
        .position(|w| w == marker)
        .expect("T3 Code's list of roles");
    let end = bytes[start..]
        .iter()
        .position(|b| !(b.is_ascii_alphanumeric() || *b == b'.'))
        .unwrap();
    let installed: BTreeSet<&str> = std::str::from_utf8(&bytes[start..start + end])
        .unwrap()
        .split('.')
        .collect();
    let ours: BTreeSet<&str> = ROLES.into_iter().collect();
    assert_eq!(
        installed,
        ours,
        "T3 Code at {} has other roles",
        asar.display()
    );
}
