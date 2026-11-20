//! nova-share-picker: what an app may show of the screen, chosen on Nova's
//! card: a screen, a window, or an area drawn with slurp.
//!
//! xdg-desktop-portal-hyprland runs it for each request to share the screen
//! (screencopy:custom_picker_binary in ~/.config/hypr/xdph.conf, which the
//! daemon writes when it is missing), with the windows it can share in
//! XDPH_WINDOW_SHARING_LIST and the screens in XDPH_OUTPUT_SHARING_LIST, and
//! reads the choice from its standard output: "[SELECTION]<flags>/<what>",
//! with "r" in the flags when the app may share it again without asking.
//! Nothing printed is a cancel. Without a Nova shell to ask on, Hyprland's own
//! picker asks.

use std::collections::BTreeMap;
use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::process::Command;

use crate::common::{write_atomically, Context};
use crate::hypr;
use crate::json::{self, Json};
use crate::prompt::{Ask, Choice, Dialog, Glyph, Toggle};

/// A window xdph can share: <handle> is what the answer names it by.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Window {
    pub handle: String,
    pub class: String,
    pub title: String,
}

/// A screen xdph can share, at its logical size.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Output {
    pub name: String,
    pub width: u32,
    pub height: u32,
}

/// XDPH_WINDOW_SHARING_LIST: "<handle>[HC>]<class>[HT>]<title>[HE>]<address>[HA>]"
/// after one another. xdph takes the markers out of titles, so a title cannot
/// make one; an entry whose handle is not a number is left out, as xdph's own
/// picker does.
pub fn windows(list: &str) -> Vec<Window> {
    list.split("[HA>]")
        .filter_map(|entry| {
            let (handle, rest) = entry.split_once("[HC>]")?;
            let (class, rest) = rest.split_once("[HT>]")?;
            let (title, _address) = rest.split_once("[HE>]")?;
            handle.parse::<u32>().ok()?;
            Some(Window {
                handle: handle.to_owned(),
                class: class.trim().to_owned(),
                title: title.trim().to_owned(),
            })
        })
        .collect()
}

/// XDPH_OUTPUT_SHARING_LIST: "<length>:<name>:<x>:<y>:<width>:<height>;" for
/// each screen, the name's length first so that it may hold a colon.
pub fn outputs(list: &str) -> Vec<Output> {
    let mut found = Vec::new();
    let mut rest = list;
    while let Some((length, after)) = rest.split_once(':') {
        let Ok(length) = length.parse::<usize>() else {
            break;
        };
        let (Some(name), Some(after)) = (after.get(..length), after.get(length..)) else {
            break;
        };
        let Some(after) = after.strip_prefix(':') else {
            break;
        };
        let (record, next) = after.split_once(';').unwrap_or((after, ""));
        let numbers: Vec<&str> = record.split(':').collect();
        if let [_, _, width, height] = numbers[..] {
            if let (Ok(width), Ok(height)) = (width.parse(), height.parse()) {
                found.push(Output {
                    name: name.to_owned(),
                    width,
                    height,
                });
            }
        }
        rest = next;
    }
    found
}

/// What a screen is called and its size in pixels, from Hyprland
/// (`j/monitors`): the built-in one is the built-in display, another its
/// model.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Screen {
    pub label: String,
    pub pixels: Option<(u32, u32)>,
}

pub fn screens(monitors: &str) -> BTreeMap<String, Screen> {
    let doc = json::parse(monitors);
    let list = doc.as_ref().and_then(Json::as_array).unwrap_or(&[]);
    list.iter()
        .filter_map(|m| {
            let name = m.get("name")?.as_str()?.to_owned();
            let text = |key: &str| m.get(key).and_then(Json::as_str).unwrap_or("").trim();
            let label =
                if name.starts_with("eDP") || name.starts_with("LVDS") || name.starts_with("DSI") {
                    "Built-in Display".to_owned()
                } else if !text("model").is_empty() {
                    text("model").to_owned()
                } else {
                    text("description").to_owned()
                };
            let number = |key: &str| m.get(key).and_then(Json::as_f64).filter(|n| *n > 0.0);
            let pixels = number("width")
                .zip(number("height"))
                .map(|(w, h)| (w as u32, h as u32));
            Some((name, Screen { label, pixels }))
        })
        .collect()
}

/// An app's name for its window class, from its desktop file ("firefox" is
/// "Firefox"); the class itself when there is none.
pub fn app_name(class: &str, data_dirs: &[PathBuf]) -> String {
    if class.is_empty() || class.contains('/') {
        return class.to_owned();
    }
    let lower = class.to_lowercase();
    for dir in data_dirs {
        for name in [class, lower.as_str()] {
            let path = dir.join("applications").join(format!("{name}.desktop"));
            if let Some(found) = fs::read_to_string(&path)
                .ok()
                .as_deref()
                .and_then(desktop_name)
            {
                return found;
            }
        }
    }
    class.to_owned()
}

/// Name= in a desktop file's [Desktop Entry].
fn desktop_name(text: &str) -> Option<String> {
    let mut in_entry = false;
    for line in text.lines() {
        let line = line.trim();
        if line.starts_with('[') {
            in_entry = line == "[Desktop Entry]";
        } else if in_entry {
            if let Some(name) = line.strip_prefix("Name=") {
                let name = name.trim();
                return (!name.is_empty()).then(|| name.to_owned());
            }
        }
    }
    None
}

fn data_dirs() -> Vec<PathBuf> {
    let mut dirs = Vec::new();
    match std::env::var_os("XDG_DATA_HOME").filter(|d| !d.is_empty()) {
        Some(home) => dirs.push(PathBuf::from(home)),
        None => {
            if let Some(home) = std::env::var_os("HOME") {
                dirs.push(PathBuf::from(home).join(".local/share"));
            }
        }
    }
    let system = std::env::var("XDG_DATA_DIRS")
        .ok()
        .filter(|d| !d.is_empty())
        .unwrap_or_else(|| "/usr/local/share:/usr/share".into());
    dirs.extend(
        system
            .split(':')
            .filter(|d| !d.is_empty())
            .map(PathBuf::from),
    );
    dirs
}

/// The card: the screens, the windows (each by its title and its app), and
/// an area to draw, with the screen first chosen; and the switch that lets
/// the app share the same again without asking, on when xdph says so.
pub fn ask(
    outputs: &[Output],
    screens: &BTreeMap<String, Screen>,
    windows: &[Window],
    apps: &dyn Fn(&str) -> String,
    allow_again: bool,
) -> Ask {
    let mut ask = Ask::new(Glyph::Share, "Share Screen");
    ask.text = "Choose what the app will see.".into();
    ask.accept = "Share".into();
    for output in outputs {
        let screen = screens.get(&output.name).cloned().unwrap_or_default();
        let label = if screen.label.is_empty() {
            output.name.clone()
        } else {
            screen.label
        };
        let (w, h) = screen.pixels.unwrap_or((output.width, output.height));
        ask.choices.push(Choice {
            id: format!("screen:{}", output.name),
            label,
            detail: format!("{w} × {h}"),
            glyph: "monitor".into(),
            section: "Screens".into(),
        });
    }
    // Two screens of the same model: their names tell them apart.
    let labels: Vec<String> = ask.choices.iter().map(|c| c.label.clone()).collect();
    for (choice, output) in ask.choices.iter_mut().zip(outputs) {
        if labels.iter().filter(|l| **l == choice.label).count() > 1 {
            choice.detail = format!("{}  ·  {}", output.name, choice.detail);
        }
    }
    for window in windows {
        let app = apps(&window.class);
        let (label, detail) = if window.title.is_empty() {
            (app, String::new())
        } else {
            (window.title.clone(), app)
        };
        ask.choices.push(Choice {
            id: format!("window:{}", window.handle),
            label,
            detail,
            glyph: "window".into(),
            section: "Windows".into(),
        });
    }
    ask.choices.push(Choice {
        id: "region".into(),
        label: "Part of the Screen…".into(),
        detail: "Draw the area to share".into(),
        glyph: "region".into(),
        section: "Area".into(),
    });
    ask.toggles.push(Toggle {
        id: "again".into(),
        label: "Let the app share it again without asking".into(),
        value: allow_again,
    });
    ask
}

/// slurp's "<output> <x> <y> <width> <height>" as xdph's region: the place
/// relative to that screen, in its logical pixels, as slurp's %X %Y give it.
pub fn region(drawn: &str, outputs: &[Output]) -> Option<String> {
    let parts: Vec<&str> = drawn.split_whitespace().collect();
    let [output, x, y, w, h] = parts[..] else {
        return None;
    };
    let [x, y, w, h] = [x, y, w, h].map(|n| n.parse::<u32>().ok());
    let (x, y, w, h) = (x?, y?, w?, h?);
    if w == 0 || h == 0 || [x, y, w, h].iter().any(|n| *n > i32::MAX as u32) {
        return None;
    }
    outputs
        .iter()
        .any(|o| o.name == output)
        .then(|| format!("region:{output}@{x},{y},{w},{h}"))
}

/// The line xdph reads.
pub fn selection(what: &str, again: bool) -> String {
    format!("[SELECTION]{}/{what}", if again { "r" } else { "" })
}

/// Asks until the user chooses or cancels: an area whose drawing was
/// cancelled asks again.
fn choose(
    ctx: &Context,
    ask: &Ask,
    outputs: &[Output],
    slurp: &dyn Fn() -> Option<String>,
) -> Option<String> {
    loop {
        let mut dialog = Dialog::open(ctx, ask).ok()?;
        let values = dialog.answer();
        dialog.done();
        let values = values?;
        let again = values.get("again").is_some_and(|v| v == "true");
        let choice = values.get("choice")?;
        if choice != "region" {
            return ask
                .choices
                .iter()
                .any(|c| &c.id == choice)
                .then(|| selection(choice, again));
        }
        if let Some(area) = slurp().as_deref().and_then(|drawn| region(drawn, outputs)) {
            return Some(selection(&area, again));
        }
    }
}

fn slurp() -> Option<String> {
    let out = Command::new("slurp")
        .args(["-f", "%o %X %Y %W %H"])
        .output()
        .ok()?;
    out.status
        .success()
        .then(|| String::from_utf8_lossy(&out.stdout).trim().to_owned())
}

/// Hyprland's own picker, with what xdph gave this one.
fn hand_over() -> i32 {
    use std::os::unix::process::CommandExt;
    let args: Vec<String> = std::env::args().skip(1).collect();
    let error = Command::new("hyprland-share-picker").args(args).exec();
    eprintln!("nova-share-picker: could not run hyprland-share-picker: {error}");
    1
}

pub fn main() -> i32 {
    let ctx = match Context::from_env() {
        Ok(ctx) if shell_listens(&ctx) => ctx,
        _ => return hand_over(),
    };
    let allow_again = std::env::args().skip(1).any(|a| a == "--allow-token");
    let outputs = outputs(&std::env::var("XDPH_OUTPUT_SHARING_LIST").unwrap_or_default());
    let windows = windows(&std::env::var("XDPH_WINDOW_SHARING_LIST").unwrap_or_default());
    let screens = ctx
        .hypr
        .as_deref()
        .and_then(|h| hypr::request(h, "j/monitors").ok())
        .map(|m| screens(&m))
        .unwrap_or_default();
    let dirs = data_dirs();
    let apps = |class: &str| app_name(class, &dirs);
    let ask = ask(&outputs, &screens, &windows, &apps, allow_again);
    if let Some(line) = choose(&ctx, &ask, &outputs, &slurp) {
        let mut out = io::stdout().lock();
        let _ = writeln!(out, "{line}");
        let _ = out.flush();
    }
    0
}

fn shell_listens(ctx: &Context) -> bool {
    std::os::unix::net::UnixStream::connect(ctx.runtime.join(crate::prompt::SOCKET)).is_ok()
}

/// ~/.config/hypr/xdph.conf with Nova's picker, when there is none: the
/// user's own is left as it is.
pub fn provide_config(config_home: &Path) -> io::Result<bool> {
    let path = config_home.join("hypr/xdph.conf");
    if path.symlink_metadata().is_ok() {
        return Ok(false);
    }
    fs::create_dir_all(config_home.join("hypr"))?;
    write_atomically(&path, CONFIG)?;
    Ok(true)
}

const CONFIG: &str = include_str!("../../../../data/skel/.config/hypr/xdph.conf");

#[cfg(test)]
mod tests {
    use super::*;
    use crate::prompt::fake::Card;
    use crate::testing::context;
    use nova_sd::testing::scratch;

    const WINDOWS: &str = "12[HC>]firefox[HT>]Nova — Mozilla Firefox[HE>]94046733433904[HA>]\
        7[HC>]foot[HT>][HE>]0[HA>]x[HC>]bad[HT>]No handle[HE>]0[HA>]";
    const OUTPUTS: &str =
        "5:eDP-1:0:0:1707:1067;4:DP-2:1707:0:2560:1440;6:HDMI:3:4267:0:1920:1080;";

    #[test]
    fn xdphs_lists_are_read_as_it_writes_them() {
        assert_eq!(
            windows(WINDOWS),
            vec![
                Window {
                    handle: "12".into(),
                    class: "firefox".into(),
                    title: "Nova — Mozilla Firefox".into()
                },
                Window {
                    handle: "7".into(),
                    class: "foot".into(),
                    title: "".into()
                },
            ]
        );
        assert_eq!(
            outputs(OUTPUTS),
            vec![
                Output {
                    name: "eDP-1".into(),
                    width: 1707,
                    height: 1067
                },
                Output {
                    name: "DP-2".into(),
                    width: 2560,
                    height: 1440
                },
                Output {
                    name: "HDMI:3".into(),
                    width: 1920,
                    height: 1080
                },
            ]
        );
        assert!(windows("").is_empty() && outputs("").is_empty());
        assert!(outputs("99:short").is_empty());
    }

    #[test]
    fn screens_are_named_as_a_person_would() {
        let monitors = r#"[{"name":"eDP-1","description":"BOE 0x0BCA","make":"BOE","model":"0x0BCA","width":2560,"height":1600},
            {"name":"DP-2","description":"Dell Inc. DELL U2720Q 1","make":"Dell Inc.","model":"DELL U2720Q","width":3840,"height":2160}]"#;
        let s = screens(monitors);
        assert_eq!(
            s["eDP-1"],
            Screen {
                label: "Built-in Display".into(),
                pixels: Some((2560, 1600))
            }
        );
        assert_eq!(
            s["DP-2"],
            Screen {
                label: "DELL U2720Q".into(),
                pixels: Some((3840, 2160))
            }
        );
        assert!(screens("not json").is_empty());
    }

    #[test]
    fn an_apps_name_comes_from_its_desktop_file() {
        let dir = scratch("share-apps");
        fs::create_dir_all(dir.join("applications")).unwrap();
        fs::write(
            dir.join("applications/firefox.desktop"),
            "[Desktop Entry]\nName=Firefox\n[Desktop Action new]\nName=New Window\n",
        )
        .unwrap();
        fs::write(
            dir.join("applications/org.gnome.Nautilus.desktop"),
            "[Desktop Action x]\nName=Wrong\n[Desktop Entry]\nType=Application\nName=Files\n",
        )
        .unwrap();
        let dirs = [dir.clone()];
        assert_eq!(app_name("firefox", &dirs), "Firefox");
        assert_eq!(app_name("Firefox", &dirs), "Firefox");
        assert_eq!(app_name("org.gnome.Nautilus", &dirs), "Files");
        assert_eq!(app_name("foot", &dirs), "foot");
        assert_eq!(app_name("../x", &dirs), "../x");
    }

    #[test]
    fn the_card_lists_screens_windows_and_an_area() {
        let outs = outputs(OUTPUTS);
        let mut scr = BTreeMap::new();
        scr.insert(
            "eDP-1".to_string(),
            Screen {
                label: "Built-in Display".into(),
                pixels: Some((2560, 1600)),
            },
        );
        scr.insert(
            "DP-2".to_string(),
            Screen {
                label: "U2720Q".into(),
                pixels: None,
            },
        );
        scr.insert(
            "HDMI:3".to_string(),
            Screen {
                label: "U2720Q".into(),
                pixels: None,
            },
        );
        let apps = |c: &str| {
            if c == "firefox" {
                "Firefox".to_string()
            } else {
                c.to_string()
            }
        };
        let ask = ask(&outs, &scr, &windows(WINDOWS), &apps, false);
        let rows: Vec<(&str, &str, &str, &str)> = ask
            .choices
            .iter()
            .map(|c| {
                (
                    c.id.as_str(),
                    c.label.as_str(),
                    c.detail.as_str(),
                    c.section.as_str(),
                )
            })
            .collect();
        assert_eq!(
            rows,
            vec![
                ("screen:eDP-1", "Built-in Display", "2560 × 1600", "Screens"),
                ("screen:DP-2", "U2720Q", "DP-2  ·  2560 × 1440", "Screens"),
                (
                    "screen:HDMI:3",
                    "U2720Q",
                    "HDMI:3  ·  1920 × 1080",
                    "Screens"
                ),
                ("window:12", "Nova — Mozilla Firefox", "Firefox", "Windows"),
                ("window:7", "foot", "", "Windows"),
                (
                    "region",
                    "Part of the Screen…",
                    "Draw the area to share",
                    "Area"
                ),
            ]
        );
        assert!(!ask.toggles[0].value);
        assert_eq!(ask.accept, "Share");
    }

    #[test]
    fn an_area_is_xdphs_region_on_a_screen_it_knows() {
        let outs = outputs(OUTPUTS);
        assert_eq!(
            region("DP-2 10 20 300 200", &outs).as_deref(),
            Some("region:DP-2@10,20,300,200")
        );
        assert_eq!(region("DP-9 10 20 300 200", &outs), None);
        assert_eq!(region("DP-2 -1 20 300 200", &outs), None);
        assert_eq!(region("DP-2 10 20 0 200", &outs), None);
        assert_eq!(region("DP-2 10 20", &outs), None);
        assert_eq!(selection("screen:DP-2", true), "[SELECTION]r/screen:DP-2");
        assert_eq!(selection("window:12", false), "[SELECTION]/window:12");
    }

    #[test]
    fn the_answer_is_the_choice_and_a_cancelled_area_asks_again() {
        let dir = scratch("share-choose");
        let ctx = context(&dir);
        let outs = outputs(OUTPUTS);
        let apps = |c: &str| c.to_string();
        let ask = ask(&outs, &BTreeMap::new(), &windows(WINDOWS), &apps, false);

        let card = Card::listen(
            &ctx.runtime,
            &[
                Some(r#"{"choice":"window:12","again":"true"}"#),
                Some(r#"{"choice":"region","again":"false"}"#),
                Some(r#"{"choice":"region","again":"false"}"#),
                Some("cancel"),
                Some(r#"{"choice":"screen:DP-7"}"#),
            ],
        );
        assert_eq!(
            choose(&ctx, &ask, &outs, &|| None).as_deref(),
            Some("[SELECTION]r/window:12")
        );

        // An area whose drawing was cancelled asks again; then one drawn.
        let tries = std::cell::Cell::new(0);
        let drawn = || {
            tries.set(tries.get() + 1);
            (tries.get() == 2).then(|| "eDP-1 5 6 70 80".to_string())
        };
        assert_eq!(
            choose(&ctx, &ask, &outs, &drawn).as_deref(),
            Some("[SELECTION]/region:eDP-1@5,6,70,80")
        );
        let asks = |card: &Card| {
            card.lines()
                .iter()
                .filter(|(_, l)| l.starts_with(r#"{"type":"ask""#))
                .count()
        };
        assert_eq!(asks(&card), 3);

        // Cancelled, or a choice the card did not offer: nothing.
        assert_eq!(choose(&ctx, &ask, &outs, &|| None), None);
        assert_eq!(choose(&ctx, &ask, &outs, &|| None), None);
        assert_eq!(asks(&card), 5);
    }

    #[test]
    fn the_config_is_written_once_and_the_users_own_is_kept() {
        let dir = scratch("share-config");
        assert!(provide_config(&dir).unwrap());
        let text = fs::read_to_string(dir.join("hypr/xdph.conf")).unwrap();
        assert!(text.contains("custom_picker_binary = /usr/lib/nova/bin/nova-share-picker"));
        fs::write(
            dir.join("hypr/xdph.conf"),
            "screencopy {\n max_fps = 30\n}\n",
        )
        .unwrap();
        assert!(!provide_config(&dir).unwrap());
        assert_eq!(
            fs::read_to_string(dir.join("hypr/xdph.conf")).unwrap(),
            "screencopy {\n max_fps = 30\n}\n"
        );
    }
}
