//! Web addresses as the sync has always read them (Python's urllib.parse):
//! split, joined to a base, quoted and unquoted.

/// A port that is not one: not digits, or past 65535.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct BadPort;

#[derive(Debug, Clone, Default, PartialEq)]
pub struct Split {
    pub scheme: String,
    pub netloc: String,
    pub path: String,
    pub query: String,
    pub fragment: String,
}

fn scheme_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.')
}

/// <url> in its five parts; none for one whose brackets do not match.
pub fn split(url: &str) -> Option<Split> {
    let url: String = url
        .trim_start_matches(|c: char| c <= ' ')
        .chars()
        .filter(|c| !matches!(c, '\t' | '\r' | '\n'))
        .collect();
    let mut rest = url.as_str();
    let mut out = Split::default();
    if let Some(i) = rest.find(':') {
        let scheme = &rest[..i];
        if i > 0
            && scheme.starts_with(|c: char| c.is_ascii_alphabetic())
            && scheme.chars().all(scheme_char)
        {
            out.scheme = scheme.to_ascii_lowercase();
            rest = &rest[i + 1..];
        }
    }
    if let Some(after) = rest.strip_prefix("//") {
        let end = after.find(['/', '?', '#']).unwrap_or(after.len());
        out.netloc = after[..end].to_string();
        rest = &after[end..];
        if out.netloc.contains('[') != out.netloc.contains(']') {
            return None;
        }
    }
    if let Some((before, fragment)) = rest.split_once('#') {
        out.fragment = fragment.to_string();
        rest = before;
    }
    if let Some((before, query)) = rest.split_once('?') {
        out.query = query.to_string();
        rest = before;
    }
    out.path = rest.to_string();
    Some(out)
}

impl Split {
    fn hostinfo(&self) -> &str {
        self.netloc
            .rsplit_once('@')
            .map_or(self.netloc.as_str(), |(_, h)| h)
    }

    /// The host, lower-cased, without its brackets; none when empty.
    pub fn hostname(&self) -> Option<String> {
        let info = self.hostinfo();
        let host = if let Some(inner) = info.strip_prefix('[') {
            inner.split_once(']').map_or("", |(h, _)| h)
        } else {
            info.split_once(':').map_or(info, |(h, _)| h)
        };
        (!host.is_empty()).then(|| host.to_lowercase())
    }

    /// The port given, Ok(None) for none, Err for one that is not a port.
    pub fn port(&self) -> Result<Option<u16>, BadPort> {
        let info = self.hostinfo();
        let port = if info.starts_with('[') {
            info.split_once(']')
                .and_then(|(_, r)| r.strip_prefix(':'))
                .unwrap_or("")
        } else {
            info.split_once(':').map_or("", |(_, p)| p)
        };
        if port.is_empty() {
            return Ok(None);
        }
        if !port.bytes().all(|b| b.is_ascii_digit()) {
            return Err(BadPort);
        }
        port.parse::<u32>()
            .ok()
            .filter(|p| *p <= 65535)
            .map(|p| Some(p as u16))
            .ok_or(BadPort)
    }

    fn userinfo(&self) -> Option<&str> {
        self.netloc.rsplit_once('@').map(|(u, _)| u)
    }

    pub fn username(&self) -> Option<&str> {
        self.userinfo()
            .map(|u| u.split_once(':').map_or(u, |(n, _)| n))
    }

    pub fn password(&self) -> Option<&str> {
        self.userinfo()
            .and_then(|u| u.split_once(':').map(|(_, p)| p))
    }

    /// The parts put back together.
    pub fn unsplit(&self) -> String {
        unsplit(
            &self.scheme,
            &self.netloc,
            &self.path,
            &self.query,
            &self.fragment,
        )
    }
}

const USES_NETLOC: &[&str] = &[
    "", "http", "https", "ftp", "file", "webcal", "webcals", "ws", "wss",
];

pub fn unsplit(scheme: &str, netloc: &str, path: &str, query: &str, fragment: &str) -> String {
    let mut url = path.to_string();
    if !netloc.is_empty()
        || (!scheme.is_empty() && USES_NETLOC.contains(&scheme) && !url.starts_with("//"))
    {
        if !url.is_empty() && !url.starts_with('/') {
            url.insert(0, '/');
        }
        url = format!("//{netloc}{url}");
    } else if url.starts_with("//") {
        url = format!("//{url}");
    }
    if !scheme.is_empty() {
        url = format!("{scheme}:{url}");
    }
    if !query.is_empty() {
        url = format!("{url}?{query}");
    }
    if !fragment.is_empty() {
        url = format!("{url}#{fragment}");
    }
    url
}

/// The path without the ";params" of its last segment, and those params.
fn split_params(path: &str) -> (&str, &str) {
    let from = path.rfind('/').unwrap_or(0);
    let at = if path.contains('/') {
        path[from..].find(';').map(|i| from + i)
    } else {
        path.find(';')
    };
    match at {
        Some(i) => (&path[..i], &path[i + 1..]),
        None => (path, ""),
    }
}

fn with_params(path: &str, params: &str) -> String {
    if params.is_empty() {
        path.to_string()
    } else {
        format!("{path};{params}")
    }
}

const USES_RELATIVE: &[&str] = &[
    "", "http", "https", "ftp", "file", "ws", "wss", "webcal", "webcals",
];

/// <url> read against <base>, as a browser reads a link (RFC 3986).
pub fn join(base: &str, url: &str) -> String {
    if base.is_empty() {
        return url.to_string();
    }
    if url.is_empty() {
        return base.to_string();
    }
    let (Some(b), Some(mut u)) = (split(base), split(url)) else {
        return url.to_string();
    };
    if u.scheme.is_empty() {
        u.scheme = b.scheme.clone();
    }
    if u.scheme != b.scheme || !USES_RELATIVE.contains(&u.scheme.as_str()) {
        return url.to_string();
    }
    let (bpath, bparams) = split_params(&b.path);
    let (path, params) = split_params(&u.path);
    let (path, params) = (path.to_string(), params.to_string());
    if !u.netloc.is_empty() {
        return u.unsplit();
    }
    let netloc = b.netloc.clone();
    if path.is_empty() && params.is_empty() {
        let query = if u.query.is_empty() {
            b.query.clone()
        } else {
            u.query.clone()
        };
        return unsplit(
            &u.scheme,
            &netloc,
            &with_params(bpath, bparams),
            &query,
            &u.fragment,
        );
    }
    let mut base_parts: Vec<&str> = bpath.split('/').collect();
    if base_parts.last() != Some(&"") {
        base_parts.pop();
    }
    let segments: Vec<&str> = if path.starts_with('/') {
        path.split('/').collect()
    } else {
        let mut all: Vec<&str> = base_parts;
        all.extend(path.split('/'));
        // No empty segments in the middle: they would make "//".
        let n = all.len();
        let mut kept = Vec::with_capacity(n);
        for (i, s) in all.into_iter().enumerate() {
            if i == 0 || i == n - 1 || !s.is_empty() {
                kept.push(s);
            }
        }
        kept
    };
    let mut resolved: Vec<&str> = Vec::new();
    for seg in &segments {
        match *seg {
            ".." => {
                resolved.pop();
            }
            "." => {}
            s => resolved.push(s),
        }
    }
    if matches!(segments.last(), Some(&".") | Some(&"..")) {
        resolved.push("");
    }
    let mut joined = resolved.join("/");
    if joined.is_empty() {
        joined = "/".into();
    }
    unsplit(
        &u.scheme,
        &netloc,
        &with_params(&joined, &params),
        &u.query,
        &u.fragment,
    )
}

/// %XX decoded, the bytes read as UTF-8 (U+FFFD for what is not).
pub fn unquote(text: &str) -> String {
    if !text.contains('%') {
        return text.to_string();
    }
    let b = text.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            let hex = std::str::from_utf8(&b[i + 1..i + 3]).ok();
            if let Some(n) = hex.and_then(|h| u8::from_str_radix(h, 16).ok()) {
                out.push(n);
                i += 3;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

pub fn unquote_plus(text: &str) -> String {
    unquote(&text.replace('+', " "))
}

/// Every byte but letters, digits and "_.-~" as %XX, a space as "+".
pub fn quote_plus(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for b in text.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'_' | b'.' | b'-' | b'~' => {
                out.push(b as char)
            }
            b' ' => out.push('+'),
            b => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

/// Every byte but letters, digits, "_.-~" and those in <safe> as %XX.
pub fn quote(text: &str, safe: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for b in text.bytes() {
        if b.is_ascii_alphanumeric()
            || b"_.-~".contains(&b)
            || (b.is_ascii() && safe.contains(b as char))
        {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

/// A form's fields as a query string, in their order.
pub fn encode(fields: &[(&str, &str)]) -> String {
    fields
        .iter()
        .map(|(k, v)| format!("{}={}", quote_plus(k), quote_plus(v)))
        .collect::<Vec<_>>()
        .join("&")
}

/// A query string's fields: blank values left out, as parse_qs leaves them.
pub fn parse_query(query: &str) -> Vec<(String, String)> {
    query
        .split('&')
        .filter_map(|pair| pair.split_once('='))
        .filter(|(_, v)| !v.is_empty())
        .map(|(k, v)| (unquote_plus(k), unquote_plus(v)))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn split_and_parts() {
        let s = split("HTTPS://bob:pw@Cal.Example.com:8443/a/b?x=1#f").unwrap();
        assert_eq!(s.scheme, "https");
        assert_eq!(s.netloc, "bob:pw@Cal.Example.com:8443");
        assert_eq!(s.hostname().as_deref(), Some("cal.example.com"));
        assert_eq!(s.port(), Ok(Some(8443)));
        assert_eq!(s.username(), Some("bob"));
        assert_eq!(s.password(), Some("pw"));
        assert_eq!(
            (s.path.as_str(), s.query.as_str(), s.fragment.as_str()),
            ("/a/b", "x=1", "f")
        );
        assert_eq!(
            split("http://[::1]:80/").unwrap().hostname().as_deref(),
            Some("::1")
        );
        assert_eq!(split("http://h:x/").unwrap().port(), Err(BadPort));
        assert_eq!(split("http://h:99999/").unwrap().port(), Err(BadPort));
        assert!(split("http://[::1/").is_none());
        assert_eq!(split("http://h").unwrap().username(), None);
    }

    #[test]
    fn join_as_rfc_3986() {
        let base = "http://a/b/c/d;p?q";
        for (rel, want) in [
            ("g", "http://a/b/c/g"),
            ("./g", "http://a/b/c/g"),
            ("g/", "http://a/b/c/g/"),
            ("/g", "http://a/g"),
            ("//g", "http://g"),
            ("?y", "http://a/b/c/d;p?y"),
            ("g?y", "http://a/b/c/g?y"),
            ("#s", "http://a/b/c/d;p?q#s"),
            (";x", "http://a/b/c/;x"),
            ("", "http://a/b/c/d;p?q"),
            (".", "http://a/b/c/"),
            ("./", "http://a/b/c/"),
            ("..", "http://a/b/"),
            ("../", "http://a/b/"),
            ("../g", "http://a/b/g"),
            ("../..", "http://a/"),
            ("../../g", "http://a/g"),
            ("../../../g", "http://a/g"),
            ("https://x/y", "https://x/y"),
        ] {
            assert_eq!(join(base, rel), want, "{rel}");
        }
        assert_eq!(
            join("http://h/alice/cals/home/", ".."),
            "http://h/alice/cals/"
        );
        assert_eq!(
            join("http://h/cals/", "/alice/cals/x/"),
            "http://h/alice/cals/x/"
        );
        assert_eq!(join("http://h/cals/", "a b.ics"), "http://h/cals/a b.ics");
    }

    #[test]
    fn quoting() {
        assert_eq!(unquote("a%20b%C3%A9%zz%"), "a bé%zz%");
        assert_eq!(unquote("%E2%82"), "\u{FFFD}");
        assert_eq!(quote_plus("a b&c=é"), "a+b%26c%3D%C3%A9");
        assert_eq!(quote("x@y/z", "@"), "x@y%2Fz");
        assert_eq!(encode(&[("a", "1 2"), ("b", "")]), "a=1+2&b=");
        assert_eq!(
            parse_query("code=a%2Fb&state=x+y&empty=&flag"),
            vec![
                ("code".into(), "a/b".into()),
                ("state".into(), "x y".into())
            ]
        );
    }
}
