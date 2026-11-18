//! What the App Center shows of an app, read from an AppStream component:
//! Flathub's catalog and Arch's (archlinux-appstream-data) are both in that
//! form. Only desktop apps are kept, in English, the language Nova's own
//! words are in.

use crate::xml::{Node, Reader};

/// One screenshot: the picture shown on the app's page, and a caption.
#[derive(Debug, Default, Clone, PartialEq)]
pub struct Shot {
    pub url: String,
    pub caption: String,
}

/// A component as a catalog has it.
#[derive(Debug, Default, Clone, PartialEq)]
pub struct Component {
    /// Its AppStream ID.
    pub id: String,
    /// Other IDs it was known by (<provides><id>).
    pub aliases: Vec<String>,
    pub name: String,
    pub summary: String,
    pub developer: String,
    /// Paragraphs, and list items as "• item".
    pub description: Vec<String>,
    pub categories: Vec<String>,
    pub keywords: Vec<String>,
    pub license: String,
    pub homepage: String,
    /// The desktop entry that starts it.
    pub desktop: String,
    /// The icon's file name in the catalog's icon cache, and the size of
    /// the largest one there; and its name in an icon theme.
    pub icon_file: String,
    pub icon_size: u32,
    pub icon_name: String,
    /// An icon on the web, where the catalog has no file of it.
    pub icon_url: String,
    pub shots: Vec<Shot>,
    /// The newest release the metadata names.
    pub version: String,
    /// Arch's package (<pkgname>), or Flathub's ref (<bundle>) and the
    /// runtime it needs.
    pub package: String,
    pub bundle: String,
    pub runtime: String,
    /// Flathub has checked that it comes from its developer.
    pub verified: bool,
}

/// An element in a language other than English is a translation.
fn translated(_: &str, attrs: &[(String, String)]) -> bool {
    attrs
        .iter()
        .any(|(k, v)| k == "xml:lang" && !matches!(v.as_str(), "en" | "en_US" | "en-US" | "C"))
}

/// The paragraphs and list items of a <description>.
fn description(node: &Node) -> Vec<String> {
    let mut out = Vec::new();
    for el in node.elements() {
        match el.name.as_str() {
            "p" => {
                let t = el.text();
                if !t.is_empty() {
                    out.push(t);
                }
            }
            "ul" | "ol" => {
                for li in el.all("li") {
                    let t = li.text();
                    if !t.is_empty() {
                        out.push(format!("\u{2022} {t}"));
                    }
                }
            }
            _ => {}
        }
    }
    out
}

/// The picture to show for a screenshot: the thumbnail nearest 1248 pixels
/// wide (sharp at twice the scale on a page some 620 wide), or the source
/// image where there are no thumbnails.
fn shot(node: &Node) -> Option<Shot> {
    let mut best: Option<(u32, String)> = None;
    let mut source = String::new();
    for image in node.all("image") {
        let url = image.text();
        if !url.starts_with("https://") {
            continue;
        }
        if image.attr("type") == Some("thumbnail") {
            let width: u32 = image
                .attr("width")
                .and_then(|w| w.parse().ok())
                .unwrap_or(0);
            let distance = width.abs_diff(1248);
            if best.as_ref().is_none_or(|(d, _)| distance < *d) {
                best = Some((distance, url));
            }
        } else if source.is_empty() {
            source = url;
        }
    }
    let url = best.map(|(_, u)| u).unwrap_or(source);
    if url.is_empty() {
        return None;
    }
    let caption = node.first("caption").map(Node::text).unwrap_or_default();
    Some(Shot { url, caption })
}

pub fn component(node: &Node) -> Option<Component> {
    let kind = node.attr("type").unwrap_or("");
    if kind != "desktop-application" && kind != "desktop" {
        return None;
    }
    let id = node.first("id")?.text();
    let name = node.first("name").map(Node::text).unwrap_or_default();
    if id.is_empty() || name.is_empty() {
        return None;
    }
    let mut c = Component {
        id,
        name,
        ..Default::default()
    };
    c.summary = node.first("summary").map(Node::text).unwrap_or_default();
    c.developer = node
        .first("developer")
        .and_then(|d| d.first("name"))
        .map(Node::text)
        .or_else(|| node.first("developer_name").map(Node::text))
        .unwrap_or_default();
    if let Some(d) = node.first("description") {
        c.description = description(d);
    }
    if let Some(cats) = node.first("categories") {
        c.categories = cats
            .all("category")
            .map(Node::text)
            .filter(|t| !t.is_empty())
            .collect();
    }
    if let Some(words) = node.first("keywords") {
        c.keywords = words
            .all("keyword")
            .map(Node::text)
            .filter(|t| !t.is_empty())
            .collect();
    }
    c.license = node
        .first("project_license")
        .map(Node::text)
        .unwrap_or_default();
    c.homepage = node
        .all("url")
        .find(|u| u.attr("type") == Some("homepage"))
        .map(Node::text)
        .filter(|u| u.starts_with("https://") || u.starts_with("http://"))
        .unwrap_or_default();
    c.desktop = node
        .all("launchable")
        .find(|l| l.attr("type") == Some("desktop-id"))
        .map(Node::text)
        .unwrap_or_default();
    if let Some(provides) = node.first("provides") {
        c.aliases = provides
            .all("id")
            .map(|i| i.text())
            .filter(|a| !a.is_empty() && *a != c.id)
            .collect();
    }
    for icon in node.all("icon") {
        let text = icon.text();
        match icon.attr("type") {
            Some("cached") => {
                let width: u32 = icon.attr("width").and_then(|w| w.parse().ok()).unwrap_or(0);
                let scale: u32 = icon
                    .attr("scale")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(1)
                    .max(1);
                let size = width * scale;
                if size > c.icon_size && !text.is_empty() {
                    c.icon_size = size;
                    c.icon_file = text;
                }
            }
            Some("stock") if c.icon_name.is_empty() => c.icon_name = text,
            Some("remote") if c.icon_url.is_empty() && text.starts_with("https://") => {
                c.icon_url = text
            }
            _ => {}
        }
    }
    if let Some(shots) = node.first("screenshots") {
        // The default first, as the catalog means it to be seen.
        let mut list: Vec<&Node> = shots.all("screenshot").collect();
        list.sort_by_key(|s| s.attr("type") != Some("default"));
        c.shots = list.into_iter().filter_map(shot).take(6).collect();
    }
    if let Some(releases) = node.first("releases") {
        c.version = releases
            .all("release")
            .find_map(|r| r.attr("version").map(str::to_string))
            .unwrap_or_default();
    }
    c.package = node.first("pkgname").map(Node::text).unwrap_or_default();
    if let Some(bundle) = node
        .all("bundle")
        .find(|b| b.attr("type") == Some("flatpak"))
    {
        c.bundle = bundle.text();
        c.runtime = bundle.attr("runtime").unwrap_or("").to_string();
    }
    if let Some(custom) = node.first("custom") {
        c.verified = custom.all("value").any(|v| {
            v.attr("key") == Some("flathub::verification::verified") && v.text() == "true"
        });
    }
    Some(c)
}

/// Every desktop app in a catalog, in its order.
pub fn parse(doc: &str) -> Result<Vec<Component>, crate::xml::Error> {
    let mut reader = Reader::new(doc);
    let mut out = Vec::new();
    while let Some(node) = reader.next_element("component", &translated)? {
        if let Some(c) = component(&node) {
            out.push(c);
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    const FLATHUB: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<components version="0.8" origin="flathub">
  <component type="desktop-application">
    <id>org.gimp.GIMP</id>
    <name xml:lang="de">GNU Bildbearbeitung</name>
    <name>GNU Image Manipulation Program</name>
    <summary>High-end image creation and manipulation</summary>
    <summary xml:lang="fr">Création d'images</summary>
    <description>
      <p>GIMP is an acronym for GNU Image Manipulation
      Program.</p>
      <ul><li>Layers</li><li>Plug-ins</li></ul>
    </description>
    <description xml:lang="cs"><p>GIMP je zkratka</p></description>
    <developer><name>The GIMP team</name></developer>
    <launchable type="desktop-id">org.gimp.GIMP.desktop</launchable>
    <icon height="64" type="cached" width="64">org.gimp.GIMP.png</icon>
    <icon height="64" scale="2" type="cached" width="64">org.gimp.GIMP.png</icon>
    <icon type="stock">org.gimp.GIMP</icon>
    <url type="homepage">https://www.gimp.org/</url>
    <categories><category>Graphics</category><category>2DGraphics</category></categories>
    <keywords><keyword>Photoshop</keyword><keyword xml:lang="de">Bild</keyword></keywords>
    <project_license>GPL-3.0+</project_license>
    <screenshots>
      <screenshot>
        <image type="thumbnail" width="624" height="351">https://dl.flathub.org/b_624.png</image>
      </screenshot>
      <screenshot type="default">
        <caption>Editing</caption>
        <image type="source" width="1920" height="1080">https://dl.flathub.org/a_orig.png</image>
        <image type="thumbnail" width="1248" height="702">https://dl.flathub.org/a_1248.png</image>
        <image type="thumbnail" width="752" height="423">https://dl.flathub.org/a_752.png</image>
      </screenshot>
    </screenshots>
    <releases><release version="3.2.8" timestamp="1"/><release version="3.2.6"/></releases>
    <provides><id>gimp.desktop</id></provides>
    <bundle type="flatpak" runtime="org.gnome.Platform/x86_64/51">app/org.gimp.GIMP/x86_64/stable</bundle>
    <custom><value key="flathub::verification::verified">true</value></custom>
  </component>
  <component type="runtime"><id>org.gnome.Platform</id><name>GNOME</name></component>
  <component type="desktop">
    <id>acme.desktop</id>
    <name>Acme</name>
    <pkgname>plan9port</pkgname>
    <icon type="cached" width="64" height="64">plan9port_acme.jxl</icon>
  </component>
</components>"#;

    #[test]
    fn reads_what_the_store_shows() {
        let apps = parse(FLATHUB).unwrap();
        assert_eq!(apps.len(), 2, "the runtime is not an app");
        let g = &apps[0];
        assert_eq!(g.id, "org.gimp.GIMP");
        assert_eq!(g.name, "GNU Image Manipulation Program");
        assert_eq!(g.summary, "High-end image creation and manipulation");
        assert_eq!(
            g.description,
            vec![
                "GIMP is an acronym for GNU Image Manipulation Program.",
                "\u{2022} Layers",
                "\u{2022} Plug-ins"
            ]
        );
        assert_eq!(g.developer, "The GIMP team");
        assert_eq!(g.desktop, "org.gimp.GIMP.desktop");
        assert_eq!(
            (g.icon_file.as_str(), g.icon_size),
            ("org.gimp.GIMP.png", 128)
        );
        assert_eq!(g.icon_name, "org.gimp.GIMP");
        assert_eq!(g.homepage, "https://www.gimp.org/");
        assert_eq!(g.categories, vec!["Graphics", "2DGraphics"]);
        assert_eq!(g.keywords, vec!["Photoshop"]);
        assert_eq!(g.license, "GPL-3.0+");
        assert_eq!(g.version, "3.2.8");
        assert_eq!(g.aliases, vec!["gimp.desktop"]);
        assert_eq!(g.bundle, "app/org.gimp.GIMP/x86_64/stable");
        assert_eq!(g.runtime, "org.gnome.Platform/x86_64/51");
        assert!(g.verified);
        assert_eq!(
            g.shots,
            vec![
                Shot {
                    url: "https://dl.flathub.org/a_1248.png".into(),
                    caption: "Editing".into()
                },
                Shot {
                    url: "https://dl.flathub.org/b_624.png".into(),
                    caption: String::new()
                },
            ]
        );
        let a = &apps[1];
        assert_eq!(
            (a.id.as_str(), a.package.as_str(), a.icon_file.as_str()),
            ("acme.desktop", "plan9port", "plan9port_acme.jxl")
        );
        assert!(!a.verified);
    }
}
