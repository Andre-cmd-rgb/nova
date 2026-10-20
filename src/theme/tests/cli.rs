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
        let path = self.root.join("home/.config/nova/backgrounds").join(path);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, b"not really a jpeg").unwrap();
        path
    }
}

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
    assert_eq!(s.ok(&["color", "--file", file, "accent"]), "#6e6e6e\n");
    assert_eq!(
        s.ok(&["color", "--file", file, "nope", "accent"]),
        "#6e6e6e\n"
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
            .any(|l| l == "white\t#ffffff\t#000000\t#6e6e6e"),
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
