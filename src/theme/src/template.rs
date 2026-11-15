//! Template rendering.
//!
//! ```text
//! {{ key }}  {{ key_strip }}  {{ key_rgb }}     palette value, without #, as r,g,b
//! {{ mix a b 30% }}  (also mix_strip, mix_rgb)  a blended 30% toward b
//! {{ hypr_gradient key fallback }}              Hyprland Lua color or gradient
//! {{ gradient_start key fallback }}             first color of a gradient, #rrggbb
//! {{ shell_gradient key fallback }}             gradient as "c1 c2 45deg"
//! ```
//!
//! A token that does not resolve is left as written.

use crate::palette::{parse_amount, Palette, Rgb};

pub fn render(text: &str, palette: &Palette) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(mut start) = rest.find("{{") {
        // In "{{{ key }}" the token starts at the last brace.
        while rest[start + 2..].starts_with('{') {
            start += 1;
        }
        let Some(len) = rest[start + 2..].find("}}") else {
            break;
        };
        let end = start + 2 + len + 2;
        out.push_str(&rest[..start]);
        let token = &rest[start..end];
        match expand(&token[2..token.len() - 2], palette) {
            Some(value) => out.push_str(&value),
            None => out.push_str(token),
        }
        rest = &rest[end..];
    }
    out.push_str(rest);
    out
}

fn expand(inner: &str, p: &Palette) -> Option<String> {
    let words: Vec<&str> = inner.split_whitespace().collect();
    match words[..] {
        [key] => lookup(key, p),
        [function @ ("mix" | "mix_strip" | "mix_rgb"), a, b, amount] => {
            let color = p.rgb(a)?.mix(p.rgb(b)?, parse_amount(amount)?);
            Some(match function {
                "mix" => color.to_string(),
                "mix_strip" => color.to_string()[1..].to_owned(),
                _ => color.decimal(),
            })
        }
        [function @ ("hypr_gradient" | "gradient_start" | "shell_gradient"), key, ref fallback @ ..]
            if fallback.len() <= 1 =>
        {
            Some(gradient(
                function,
                &resolve(p, key, fallback.first().copied()),
                p,
            ))
        }
        _ => None,
    }
}

fn lookup(key: &str, p: &Palette) -> Option<String> {
    if let Some(value) = p.get(key) {
        return Some(value.to_owned());
    }
    if let Some(base) = key.strip_suffix("_strip") {
        return p
            .get(base)
            .map(|v| v.strip_prefix('#').unwrap_or(v).to_owned());
    }
    key.strip_suffix("_rgb")
        .and_then(|base| p.rgb(base))
        .map(Rgb::decimal)
}

/// A palette key, else the fallback as a key, else the fallback verbatim.
fn resolve(p: &Palette, key: &str, fallback: Option<&str>) -> String {
    p.get(key)
        .or_else(|| fallback.and_then(|f| p.get(f)))
        .unwrap_or(fallback.unwrap_or(key))
        .to_owned()
}

/// Renders a gradient spec ("c1 c2 45deg", colors as keys or literals).
fn gradient(function: &str, spec: &str, p: &Palette) -> String {
    let mut colors = Vec::new();
    let mut angle = None;
    for part in spec.split_whitespace() {
        match part.strip_suffix("deg").filter(|n| is_number(n)) {
            Some(number) => angle = Some(number),
            None => colors.push(p.get(part).unwrap_or(part)),
        }
    }

    match function {
        "hypr_gradient" if colors.len() <= 1 => {
            format!("\"{}\"", colors.first().copied().unwrap_or(spec))
        }
        "hypr_gradient" => {
            let list: Vec<String> = colors.iter().map(|c| format!("\"{c}\"")).collect();
            match angle {
                Some(a) => format!("{{ colors = {{ {} }}, angle = {a} }}", list.join(", ")),
                None => format!("{{ colors = {{ {} }} }}", list.join(", ")),
            }
        }
        "gradient_start" => to_hex(colors.first().copied().unwrap_or(spec)),
        _ if colors.is_empty() => spec.to_owned(),
        _ => match angle {
            Some(a) => format!("{} {a}deg", colors.join(" ")),
            None => colors.join(" "),
        },
    }
}

/// `-?digits(.digits)?`
fn is_number(s: &str) -> bool {
    let s = s.strip_prefix('-').unwrap_or(s);
    let (int, frac) = match s.split_once('.') {
        Some((int, frac)) => (int, Some(frac)),
        None => (s, None),
    };
    let digits = |d: &str| !d.is_empty() && d.bytes().all(|b| b.is_ascii_digit());
    digits(int) && frac.is_none_or(digits)
}

/// `#rrggbbaa`, `rgba(rrggbbaa)` and `rgb(r,g,b)` all reduce to `#rrggbb`;
/// anything else is returned as is.
fn to_hex(color: &str) -> String {
    let hex = |s: &str| (s.len() == 6 || s.len() == 8) && s.bytes().all(|b| b.is_ascii_hexdigit());
    if let Some(digits) = color.strip_prefix('#').filter(|d| hex(d)) {
        return format!("#{}", &digits[..6]);
    }

    let lower = color.to_ascii_lowercase();
    let prefix = if lower.starts_with("rgba(") {
        5
    } else if lower.starts_with("rgb(") {
        4
    } else {
        return color.to_owned();
    };
    let Some(inner) = color[prefix..].strip_suffix(')') else {
        return color.to_owned();
    };
    if hex(inner) {
        return format!("#{}", &inner[..6]);
    }

    let parts: Vec<&str> = inner.split(',').collect();
    let channel = |s: &str| {
        (!s.is_empty() && s.bytes().all(|b| b.is_ascii_digit()))
            .then(|| s.parse::<u64>().unwrap_or(u64::MAX).min(255))
    };
    let alpha_ok = parts
        .get(3)
        .is_none_or(|a| !a.is_empty() && a.bytes().all(|b| b.is_ascii_digit() || b == b'.'));
    match (
        parts.len(),
        parts.first().and_then(|s| channel(s)),
        parts.get(1).and_then(|s| channel(s)),
        parts.get(2).and_then(|s| channel(s)),
    ) {
        (3 | 4, Some(r), Some(g), Some(b)) if alpha_ok => format!("#{r:02x}{g:02x}{b:02x}"),
        _ => color.to_owned(),
    }
}

/// The table name of a `[name]` header line (not `[[array]]`), allowing a
/// trailing comment.
fn header(line: &str) -> Option<&str> {
    let rest = line.trim_start().strip_prefix('[')?;
    if rest.starts_with('[') {
        return None;
    }
    let end = rest.find(']')?;
    let after = rest[end + 1..].trim_start();
    (end > 0 && (after.is_empty() || after.starts_with('#'))).then(|| &rest[..end])
}

/// Replaces `[section]` of a TOML document with the body of `replacement`, or
/// appends it when the document has no such section.
pub fn replace_section(toml: &str, section: &str, replacement: &str) -> String {
    let body: Vec<&str> = replacement
        .lines()
        .filter(|l| header(l) != Some(section))
        .collect();
    let body = body.join("\n");
    let block = format!("[{section}]\n{}\n", body.trim_end_matches('\n'));

    let mut out = String::with_capacity(toml.len() + block.len());
    let mut inside = false;
    let mut done = false;
    for line in toml.lines() {
        if let Some(name) = header(line) {
            if inside {
                out.push_str(&block);
                out.push('\n');
                inside = false;
                done = true;
            }
            if name == section {
                inside = true;
                continue;
            }
        }
        if !inside {
            out.push_str(line);
            out.push('\n');
        }
    }
    if !done {
        if !inside && !out.is_empty() {
            out.push('\n');
        }
        out.push_str(&block);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn palette() -> Palette {
        Palette::from_text(
            "background = \"#ffffff\"\nforeground = \"#000000\"\nborder = \"accent blue 45deg\"\naccent = \"#6e6e6e\"\n",
        )
    }

    #[test]
    fn renders_keys_and_their_variants() {
        let p = palette();
        assert_eq!(
            render(
                "a {{ background }} {{background_strip}} {{ foreground_rgb }} b",
                &p
            ),
            "a #ffffff ffffff 0,0,0 b"
        );
    }

    #[test]
    fn leaves_unknown_tokens_alone() {
        let p = palette();
        assert_eq!(
            render("{{ nope }} {{ mix background nope 3% }} {{ x", &p),
            "{{ nope }} {{ mix background nope 3% }} {{ x"
        );
        assert_eq!(render("{ {{{ background }} }", &p), "{ {#ffffff }");
    }

    #[test]
    fn mixes() {
        let p = palette();
        assert_eq!(render("{{ mix foreground background 43% }}", &p), "#6e6e6e");
        assert_eq!(
            render("{{ mix_strip foreground background 0.43 }}", &p),
            "6e6e6e"
        );
        assert_eq!(
            render("{{ mix_rgb foreground background 43% }}", &p),
            "110,110,110"
        );
    }

    #[test]
    fn renders_gradients() {
        let p = palette();
        assert_eq!(
            render("{{ hypr_gradient border accent }}", &p),
            "{ colors = { \"#6e6e6e\", \"#000000\" }, angle = 45 }"
        );
        assert_eq!(
            render("{{ hypr_gradient missing accent }}", &p),
            "\"#6e6e6e\""
        );
        assert_eq!(
            render("{{ shell_gradient border accent }}", &p),
            "#6e6e6e #000000 45deg"
        );
        assert_eq!(render("{{ gradient_start border accent }}", &p), "#6e6e6e");
    }

    #[test]
    fn reduces_colors_to_hex() {
        assert_eq!(to_hex("#11223344"), "#112233");
        assert_eq!(to_hex("rgba(aabbccdd)"), "#aabbcc");
        assert_eq!(to_hex("RGB(300,0,16)"), "#ff0010");
        assert_eq!(to_hex("rgba(1,2,3,0.5)"), "#010203");
        assert_eq!(to_hex("rgb(1, 2, 3)"), "rgb(1, 2, 3)");
        assert_eq!(to_hex("blue"), "blue");
    }

    #[test]
    fn replaces_a_middle_section() {
        let toml = "[a]\nx = 1\n\n[lock]\ny = 2\n\n[b]\nz = 3\n";
        assert_eq!(
            replace_section(toml, "lock", "[lock]\ny = 9\n"),
            "[a]\nx = 1\n\n[lock]\ny = 9\n\n[b]\nz = 3\n"
        );
    }

    #[test]
    fn replaces_a_last_section_and_appends_a_missing_one() {
        assert_eq!(
            replace_section("[a]\nx = 1\n\n[lock]\ny = 2\n", "lock", "y = 9"),
            "[a]\nx = 1\n\n[lock]\ny = 9\n"
        );
        assert_eq!(
            replace_section("[a]\nx = 1\n", "lock", "y = 9\n\n"),
            "[a]\nx = 1\n\n[lock]\ny = 9\n"
        );
        assert_eq!(
            replace_section("[[a]]\n[lock] # c\n", "lock", "y = 9"),
            "[[a]]\n[lock]\ny = 9\n"
        );
    }
}
