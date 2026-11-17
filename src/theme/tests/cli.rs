//! Drives the nova-theme binary against a scratch home, with the repository's
//! palettes and templates as Nova's data and stubs for the commands it calls.

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::atomic::{AtomicUsize, Ordering};

const REPO: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../..");

struct Sandbox {
    root: PathBuf,
}

impl Sandbox {
    fn new() -> Sandbox {
        static COUNTER: AtomicUsize = AtomicUsize::new(0);
        let root = std::env::temp_dir().join(format!(
            "nova-theme-test.{}.{}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = fs::remove_dir_all(&root);
        let share = root.join("share");
        for (from, to) in [
            ("theme/palettes", "themes"),
            ("theme/templates", "templates"),
            ("theme/wordmark", "wordmark"),
        ] {
            copy_dir(&Path::new(REPO).join(from), &share.join(to));
        }
        // Each stub records its arguments, one call per line.
        let bin = root.join("bin");
        fs::create_dir_all(&bin).unwrap();
        for stub in ["nova-shell", "nova-theme-apply", "nova-hook"] {
            let path = bin.join(stub);
            fs::write(
                &path,
                format!(
                    "#!/bin/sh\necho \"$*\" >> \"{}/{stub}.log\"\n",
                    root.display()
                ),
            )
            .unwrap();
            fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
        }
        // vipsthumbnail <image> --size <WxH> --path <out>: the tests' photos
        // are PPMs already (`ppm`), handed on as they are.
        let vips = bin.join("vipsthumbnail");
        fs::write(
            &vips,
            "#!/bin/sh\nimage=$1\nwhile [ $# -gt 1 ]; do shift; done\ncp \"$image\" \"$1\"\n",
        )
        .unwrap();
        fs::set_permissions(&vips, fs::Permissions::from_mode(0o755)).unwrap();
        fs::create_dir_all(root.join("home/.config/nova/backgrounds")).unwrap();
        fs::create_dir_all(root.join("run")).unwrap();
        Sandbox { root }
    }

    fn run(&self, args: &[&str]) -> Output {
        Command::new(env!("CARGO_BIN_EXE_nova-theme"))
            .args(args)
            .env_clear()
            .env(
                "PATH",
                format!("{}:/usr/bin:/bin", self.root.join("bin").display()),
            )
            .env("HOME", self.root.join("home"))
            .env("NOVA_PATH", self.root.join("share"))
            .env("XDG_RUNTIME_DIR", self.root.join("run"))
            .output()
            .unwrap()
    }

    fn ok(&self, args: &[&str]) -> String {
        let out = self.run(args);
        assert!(
            out.status.success(),
            "nova-theme {args:?} failed: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        String::from_utf8(out.stdout).unwrap()
    }

    fn state(&self) -> PathBuf {
        self.root.join("home/.local/state/nova")
    }

    fn background(&self) -> PathBuf {
        fs::read_link(self.state().join("current/background")).unwrap()
    }

    fn log(&self, stub: &str) -> String {
        fs::read_to_string(self.root.join(format!("{stub}.log"))).unwrap_or_default()
    }

    fn photo(&self, path: &str) -> PathBuf {
        self.photo_of(path, b"not really a jpeg")
    }

    fn photo_of(&self, path: &str, contents: &[u8]) -> PathBuf {
        let path = self.root.join("home/.config/nova/backgrounds").join(path);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, contents).unwrap();
        path
    }

    fn color(&self, key: &str) -> String {
        self.ok(&["color", key]).trim().to_owned()
    }
}

/// A photo as the engine reads one: 64 by 36 pixels, the top five rows of
/// one color and the rest of another.
fn ppm(top: [u8; 3], rest: [u8; 3]) -> Vec<u8> {
    let mut bytes = b"P6\n64 36\n255\n".to_vec();
    for row in 0..36 {
        for _ in 0..64 {
            bytes.extend(if row < 5 { top } else { rest });
        }
    }
    bytes
}

const DUSK_PINK: [u8; 3] = [0xd0, 0x80, 0xb0];
const DEEP_BLUE: [u8; 3] = [0x20, 0x30, 0x60];
const PAPER: [u8; 3] = [0xf2, 0xee, 0xe2];
/// The adaptive theme's background with no photo to take one from.
const ADAPTIVE_OWN: &str = "#151926";

impl Drop for Sandbox {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn copy_dir(from: &Path, to: &Path) {
    fs::create_dir_all(to).unwrap();
    for entry in fs::read_dir(from).unwrap() {
        let path = entry.unwrap().path();
        let target = to.join(path.file_name().unwrap());
        if path.is_dir() {
            copy_dir(&path, &target)
        } else {
            fs::copy(&path, &target).map(drop).unwrap()
        }
    }
}

#[test]
fn sets_a_theme_atomically_and_tells_the_shell() {
    let s = Sandbox::new();
    s.ok(&["set", "Tokyo Night"]);

    let theme = s.state().join("current/theme");
    assert!(fs::symlink_metadata(&theme)
        .unwrap()
        .file_type()
        .is_symlink());
    for file in [
        "colors.toml",
        "hyprland.lua",
        "gtk4.css",
        "foot.ini",
        "shell.toml",
        "backgrounds/nova.svg",
    ] {
        assert!(theme.join(file).is_file(), "missing {file}");
    }
    assert!(!theme.join("nova.svg").exists());
    assert_eq!(s.ok(&["current"]), "tokyo-night\n");
    assert_eq!(s.background(), theme.join("backgrounds/nova.svg"));
    assert!(s
        .log("nova-shell")
        .starts_with("-q background themeTransition "));
    assert_eq!(s.log("nova-theme-apply"), "\n");
    assert_eq!(s.log("nova-hook"), "theme-set tokyo-night\n");

    s.ok(&["set", "white"]);
    assert_eq!(fs::read_dir(s.state().join("rendered")).unwrap().count(), 1);
    assert!(s.ok(&["color", "background"]).starts_with("#ffffff"));
    // The old wordmark went with its render; the shell fades from a held copy.
    let held = s
        .log("nova-shell")
        .lines()
        .nth(1)
        .unwrap()
        .split(' ')
        .nth(3)
        .unwrap()
        .to_owned();
    assert!(held.ends_with("background-previous.svg"), "{held}");
    assert!(fs::read_to_string(held).unwrap().contains("#1a1b26"));
}

#[test]
fn refresh_renders_the_theme_again_only_when_a_template_changed() {
    let s = Sandbox::new();
    // No theme set: nothing to do.
    s.ok(&["refresh"]);
    assert_eq!(s.log("nova-theme-apply"), "");

    s.ok(&["set", "nord"]);
    s.ok(&["refresh"]);
    assert_eq!(
        s.log("nova-theme-apply").lines().count(),
        1,
        "refreshed a render up to date"
    );

    // An update brings a new template.
    let foot = s.root.join("share/templates/foot.ini.tpl");
    let mut text = fs::read_to_string(&foot).unwrap();
    text.push_str("# new in this update\n");
    fs::write(&foot, text).unwrap();
    s.ok(&["refresh"]);
    assert_eq!(s.log("nova-theme-apply").lines().count(), 2);
    let rendered = fs::read_to_string(s.state().join("current/theme/foot.ini")).unwrap();
    assert!(rendered.contains("# new in this update"));
    assert_eq!(s.ok(&["current"]), "nord\n");
    s.ok(&["refresh"]);
    assert_eq!(s.log("nova-theme-apply").lines().count(), 2);

    // A render from before Nova kept what it was made from is made again, once.
    fs::remove_file(s.state().join("current/theme/.made-from")).unwrap();
    s.ok(&["refresh"]);
    s.ok(&["refresh"]);
    assert_eq!(s.log("nova-theme-apply").lines().count(), 3);

    // A theme of the user's own, changed, is too.
    let mine = s.root.join("home/.config/nova/themes/nord");
    fs::create_dir_all(&mine).unwrap();
    fs::write(mine.join("btop.theme"), "theme[main_bg]=\"#000000\"\n").unwrap();
    s.ok(&["refresh"]);
    assert_eq!(s.log("nova-theme-apply").lines().count(), 4);
}

#[test]
fn rejects_bad_and_unknown_names() {
    let s = Sandbox::new();
    assert_eq!(s.run(&["set", "../x"]).status.code(), Some(2));
    assert_eq!(s.run(&["set", "nope"]).status.code(), Some(1));
    assert_eq!(s.run(&["frobnicate"]).status.code(), Some(2));
    assert!(!s.state().join("current/theme").exists());
}

#[test]
fn a_shared_photo_follows_theme_switches_until_a_theme_picks_its_own() {
    let s = Sandbox::new();
    let photo = s.photo("mountain.jpg");
    s.ok(&["set", "white"]);
    s.ok(&["bg", "set", photo.to_str().unwrap()]);
    assert_eq!(s.background(), photo);

    s.ok(&["set", "nord"]);
    assert_eq!(s.background(), photo);

    // Nord picks its own wordmark; white keeps the photo.
    let wordmark = s.state().join("current/theme/backgrounds/nova.svg");
    s.ok(&["bg", "set", wordmark.to_str().unwrap()]);
    s.ok(&["set", "white"]);
    assert_eq!(s.background(), photo);
    s.ok(&["set", "nord"]);
    assert_eq!(s.background(), wordmark);
    assert!(fs::read_to_string(&wordmark).unwrap().contains("#2e3440"));
}

#[test]
fn a_per_theme_photo_stays_with_its_theme() {
    let s = Sandbox::new();
    let photo = s.photo("white/snow.png");
    s.ok(&["set", "white"]);
    s.ok(&["bg", "set", photo.to_str().unwrap()]);
    s.ok(&["set", "nord"]);
    assert_eq!(
        s.background(),
        s.state().join("current/theme/backgrounds/nova.svg")
    );
    s.ok(&["set", "white"]);
    assert_eq!(s.background(), photo);
}

#[test]
fn lists_and_cycles_backgrounds() {
    let s = Sandbox::new();
    let a = s.photo("a.jpg");
    let b = s.photo("b.webp");
    s.photo("notes.txt");
    s.ok(&["set", "white"]);

    let wordmark = s.state().join("current/theme/backgrounds/nova.svg");
    let listed = s.ok(&["bg", "list"]);
    assert_eq!(
        listed,
        format!("{}\n{}\n{}\n", wordmark.display(), a.display(), b.display())
    );

    s.ok(&["bg", "next"]);
    assert_eq!(s.background(), a);
    s.ok(&["bg", "next"]);
    assert_eq!(s.background(), b);
    s.ok(&["bg", "next"]);
    assert_eq!(s.background(), wordmark);
    assert!(
        s.log("nova-theme-apply")
            .lines()
            .filter(|l| *l == "greeter")
            .count()
            == 3
    );
    assert!(
        s.run(&[
            "bg",
            "set",
            s.root
                .join("home/.config/nova/backgrounds/notes.txt")
                .to_str()
                .unwrap()
        ])
        .status
        .code()
            == Some(1)
    );
}

#[test]
fn resolves_colors_with_fallbacks() {
    let s = Sandbox::new();
    let file = s.root.join("share/themes/white/colors.toml");
    let file = file.to_str().unwrap();
    assert_eq!(s.ok(&["color", "--file", file, "accent"]), "#575757\n");
    assert_eq!(
        s.ok(&["color", "--file", file, "nope", "accent"]),
        "#575757\n"
    );
    assert_eq!(
        s.ok(&["color", "--file", file, "nope", "#123456"]),
        "#123456\n"
    );
    assert_eq!(
        s.run(&["color", "--file", file, "nope"]).status.code(),
        Some(1)
    );
    assert!(s
        .ok(&["color", "--file", file, "--all"])
        .contains("mode\tlight\n"));
    assert_eq!(s.ok(&["mix", "#000000", "#ffffff", "43%"]), "#6e6e6e\n");
}

#[test]
fn lists_themes_with_their_colors() {
    let s = Sandbox::new();
    let names = s.ok(&["list"]);
    let colored = s.ok(&["list", "--colors"]);
    assert_eq!(names.lines().count(), colored.lines().count());
    assert!(
        colored
            .lines()
            .any(|l| l == "white\t#ffffff\t#121212\t#575757"),
        "{colored}"
    );
    // The user's palette wins over Nova's.
    let mine = s.root.join("home/.config/nova/themes/white");
    fs::create_dir_all(&mine).unwrap();
    fs::write(
        mine.join("colors.toml"),
        "background = \"#101010\"\nforeground = \"#fafafa\"\naccent = \"#ff0000\"\n",
    )
    .unwrap();
    assert!(s
        .ok(&["list", "--colors"])
        .lines()
        .any(|l| l == "white\t#101010\t#fafafa\t#ff0000"));
}

#[test]
fn the_adaptive_theme_takes_its_colors_from_the_background() {
    let s = Sandbox::new();
    s.ok(&["set", "adaptive"]);
    assert_eq!(s.color("background"), ADAPTIVE_OWN);

    // A new background is the theme set again, with the photo's colors.
    let dusk = s.photo_of("dusk.png", &ppm(DUSK_PINK, DEEP_BLUE));
    s.ok(&["bg", "set", dusk.to_str().unwrap()]);
    assert_eq!(s.background(), dusk);
    assert_eq!(s.ok(&["current"]), "adaptive\n");
    let from_dusk = s.color("background");
    assert_ne!(from_dusk, ADAPTIVE_OWN);
    assert_eq!(s.color("mode"), "dark");
    assert_eq!(s.color("adaptive"), "auto");
    let theme = s.state().join("current/theme");
    let colors = fs::read_to_string(theme.join("colors.toml")).unwrap();
    assert!(colors.contains(dusk.to_str().unwrap()), "{colors}");
    // The border runs between the photo's two colors.
    let hyprland = fs::read_to_string(theme.join("hyprland.lua")).unwrap();
    assert!(
        hyprland.contains("local focused = { colors = { \"#"),
        "{hyprland}"
    );
    // The shell is told of the photo and the colors in one step, and every
    // app is themed again.
    let shell = s.log("nova-shell");
    let last = shell.lines().last().unwrap();
    assert!(last.starts_with("-q background themeTransition "), "{last}");
    assert!(last.contains(dusk.to_str().unwrap()), "{last}");
    assert_eq!(s.log("nova-theme-apply"), "\n\n");

    // A pale photo makes it a light theme.
    let paper = s.photo_of("paper.png", &ppm(PAPER, PAPER));
    s.ok(&["bg", "set", paper.to_str().unwrap()]);
    assert_eq!(s.color("mode"), "light");
    let from_paper = s.color("background");
    assert_ne!(from_paper, from_dusk);

    // Another theme keeps its own colors with that photo behind it, and
    // the list shows the adaptive theme as the photo would make it.
    s.ok(&["set", "nord"]);
    assert_eq!(s.color("background"), "#2e3440");
    assert_eq!(s.background(), paper);
    let listed = s.ok(&["list", "--colors"]);
    let adaptive = listed
        .lines()
        .find(|l| l.starts_with("adaptive\t"))
        .unwrap();
    assert_eq!(adaptive.split('\t').nth(1), Some(from_paper.as_str()));
    s.ok(&["set", "adaptive"]);
    assert_eq!(s.color("background"), from_paper);
}

#[test]
fn the_adaptive_theme_is_kept_dark_or_light_when_that_is_chosen() {
    let s = Sandbox::new();
    let paper = s.photo_of("paper.png", &ppm(PAPER, PAPER));
    s.ok(&["set", "nord"]);
    s.ok(&["bg", "set", paper.to_str().unwrap()]);
    // Not an adaptive theme: nothing to print, and the choice is kept for one.
    assert_eq!(s.run(&["adaptive"]).status.code(), Some(1));
    assert_eq!(s.run(&["adaptive", "dim"]).status.code(), Some(2));

    s.ok(&["set", "adaptive"]);
    assert_eq!(s.ok(&["adaptive"]), "auto\n");
    assert_eq!(s.color("mode"), "light");
    let light = s.color("background");

    // Chosen dark, the theme is set again, dark on the same pale photo.
    s.ok(&["adaptive", "dark"]);
    assert_eq!(s.ok(&["adaptive"]), "dark\n");
    assert_eq!(s.color("mode"), "dark");
    assert_ne!(s.color("background"), light);
    let transitions = s.log("nova-shell").matches("themeTransition").count();

    // It stays dark across a switch away and back, and the list shows it so.
    s.ok(&["set", "nord"]);
    s.ok(&["adaptive", "dark"]);
    assert_eq!(
        s.log("nova-shell").matches("themeTransition").count(),
        transitions + 1
    );
    s.ok(&["set", "adaptive"]);
    assert_eq!(s.color("mode"), "dark");

    s.ok(&["adaptive", "auto"]);
    assert_eq!(s.color("mode"), "light");
    assert_eq!(s.color("background"), light);
}

#[test]
fn the_adaptive_theme_keeps_its_own_colors_without_a_photo_it_can_read() {
    let s = Sandbox::new();
    let broken = s.photo("broken.jpg");
    s.ok(&["set", "adaptive"]);
    let out = s.run(&["bg", "set", broken.to_str().unwrap()]);
    assert!(out.status.success());
    assert!(String::from_utf8_lossy(&out.stderr).contains("keeps the colors it came with"));
    assert_eq!(s.color("background"), ADAPTIVE_OWN);
    assert_eq!(s.background(), broken);

    // Its own wordmark is drawn in its colors, so it is not read for them.
    let wordmark = s.state().join("current/theme/backgrounds/nova.svg");
    s.ok(&["bg", "set", wordmark.to_str().unwrap()]);
    assert_eq!(s.color("background"), ADAPTIVE_OWN);
    assert!(fs::read_to_string(&wordmark)
        .unwrap()
        .contains(ADAPTIVE_OWN));
}

#[test]
fn prints_the_palette_a_photo_gives() {
    let s = Sandbox::new();
    let dusk = s.photo_of("dusk.png", &ppm(DUSK_PINK, DEEP_BLUE));
    let auto = s.ok(&["palette", dusk.to_str().unwrap()]);
    assert!(auto.contains("mode = \"dark\"\n") && auto.contains("adaptive = \"auto\"\n"));
    assert!(auto.contains("\naccent = \"#") && auto.contains("\nbright_cyan = \"#"));
    let light = s.ok(&["palette", dusk.to_str().unwrap(), "light"]);
    assert!(light.contains("mode = \"light\"\n") && light.contains("adaptive = \"light\"\n"));
    assert_eq!(
        s.run(&["palette", dusk.to_str().unwrap(), "dim"])
            .status
            .code(),
        Some(2)
    );
    assert_eq!(
        s.run(&["palette", "/nonexistent.png"]).status.code(),
        Some(1)
    );
}

#[test]
fn picks_the_ink_and_shade_of_a_see_through_bar() {
    let s = Sandbox::new();
    // Nothing behind the bar yet: the theme's text, unshaded.
    assert_eq!(
        s.ok(&["bar", "top", "40", "1920x1080", "#d8dee9", "#2e3440"]),
        "#d8dee9 #2e3440 0.00\n"
    );

    // A pale sky over deep water. The top 40 of 1080 pixels are the sky.
    let photo = s.photo_of("lake.png", &ppm(PAPER, DEEP_BLUE));
    s.ok(&["set", "nord"]);
    s.ok(&["bg", "set", photo.to_str().unwrap()]);
    assert_eq!(
        s.ok(&["bar", "top", "40", "1920x1080", "#d8dee9", "#2e3440"]),
        "#2e3440 #d8dee9 0.00\n"
    );
    assert_eq!(
        s.ok(&["bar", "bottom", "40", "1920x1080", "#d8dee9", "#2e3440"]),
        "#d8dee9 #2e3440 0.00\n"
    );
    // Down the side it is mostly water, with the sky at its top: the theme's
    // text still, and a shade for where the sky is.
    let left = s.ok(&["bar", "left", "40", "1920x1080", "#d8dee9", "#2e3440"]);
    let fields: Vec<&str> = left.split_whitespace().collect();
    assert_eq!(fields[..2], ["#d8dee9", "#2e3440"]);
    assert!(fields[2].parse::<f64>().unwrap() > 0.0, "{left}");

    for bad in [
        ["bar", "middle", "40", "1920x1080", "#d8dee9", "#2e3440"],
        ["bar", "top", "40", "1920", "#d8dee9", "#2e3440"],
        ["bar", "top", "40", "1920x1080", "d8dee9", "#2e3440"],
    ] {
        assert_eq!(s.run(&bad).status.code(), Some(2), "{bad:?}");
    }
}
