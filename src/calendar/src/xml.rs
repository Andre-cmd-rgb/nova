//! Enough XML for WebDAV's answers, read as Python's ElementTree reads them:
//! a tree of elements, each named "{namespace}local" (or "local" with none),
//! its attributes, and its text up to its first child; comments and
//! processing instructions left out, a document that is not well formed
//! refused.

#[derive(Debug, Clone, Default)]
pub struct Element {
    pub tag: String,
    pub attrs: Vec<(String, String)>,
    /// The text before the first child element (ElementTree's `.text`).
    pub text: String,
    pub children: Vec<Element>,
}

impl Element {
    /// The first child element named <tag>.
    pub fn find(&self, tag: &str) -> Option<&Element> {
        self.children.iter().find(|c| c.tag == tag)
    }

    pub fn findall<'a>(&'a self, tag: &'a str) -> impl Iterator<Item = &'a Element> + 'a {
        self.children.iter().filter(move |c| c.tag == tag)
    }

    /// The text of the first child named <tag>: "" for one with none, None
    /// for no such child.
    pub fn findtext(&self, tag: &str) -> Option<&str> {
        self.find(tag).map(|c| c.text.as_str())
    }

    pub fn get(&self, name: &str) -> Option<&str> {
        self.attrs
            .iter()
            .find(|(k, _)| k == name)
            .map(|(_, v)| v.as_str())
    }

    /// Every element named <tag>, this one and those under it, in the
    /// order of the document.
    pub fn iter<'a>(&'a self, tag: &str) -> Vec<&'a Element> {
        let mut out = Vec::new();
        fn walk<'a>(e: &'a Element, tag: &str, out: &mut Vec<&'a Element>) {
            if e.tag == tag {
                out.push(e);
            }
            for c in &e.children {
                walk(c, tag, out);
            }
        }
        walk(self, tag, &mut out);
        out
    }
}

/// The document element of <bytes>; none when it is not well formed.
pub fn parse(bytes: &[u8]) -> Option<Element> {
    // Line ends are one "\n" in XML, whatever the document has.
    let text = String::from_utf8_lossy(bytes)
        .replace("\r\n", "\n")
        .replace('\r', "\n");
    let mut p = Parser {
        s: text.strip_prefix('\u{feff}').unwrap_or(&text),
        at: 0,
        scopes: Vec::new(),
    };
    p.misc()?;
    if !p.s[p.at..].starts_with('<') {
        return None;
    }
    let root = p.element(0)?;
    p.misc()?;
    (p.at == p.s.len()).then_some(root)
}

struct Parser<'a> {
    s: &'a str,
    at: usize,
    /// The namespaces declared on each open element: (prefix, URI), the
    /// prefix "" for the default one.
    scopes: Vec<Vec<(String, String)>>,
}

fn is_name_char(c: char) -> bool {
    c.is_alphanumeric() || matches!(c, '_' | '-' | '.' | ':') || (c as u32) > 0x7f
}

impl Parser<'_> {
    fn rest(&self) -> &str {
        &self.s[self.at..]
    }

    fn skip_space(&mut self) {
        let rest = self.rest();
        let trimmed = rest.trim_start_matches([' ', '\t', '\r', '\n']);
        self.at += rest.len() - trimmed.len();
    }

    /// Past the next <end>; none where there is none.
    fn past(&mut self, end: &str) -> Option<&str> {
        let i = self.rest().find(end)?;
        let found = &self.s[self.at..self.at + i];
        self.at += i + end.len();
        Some(found)
    }

    /// White space, comments, processing instructions and a DOCTYPE, as
    /// before and after the document element.
    fn misc(&mut self) -> Option<()> {
        loop {
            self.skip_space();
            let rest = self.rest();
            if rest.starts_with("<?") {
                self.past("?>")?;
            } else if rest.starts_with("<!--") {
                self.past("-->")?;
            } else if rest.starts_with("<!DOCTYPE") {
                self.doctype()?;
            } else {
                return Some(());
            }
        }
    }

    fn doctype(&mut self) -> Option<()> {
        let mut depth = 0;
        let mut quote: Option<char> = None;
        for (i, c) in self.rest().char_indices() {
            match (quote, c) {
                (Some(q), c) if c == q => quote = None,
                (Some(_), _) => {}
                (None, '"' | '\'') => quote = Some(c),
                (None, '[') => depth += 1,
                (None, ']') => depth -= 1,
                (None, '>') if depth == 0 => {
                    self.at += i + 1;
                    return Some(());
                }
                _ => {}
            }
        }
        None
    }

    fn name(&mut self) -> Option<&str> {
        let rest = self.rest();
        let end = rest.find(|c: char| !is_name_char(c)).unwrap_or(rest.len());
        if end == 0 {
            return None;
        }
        let name = &self.s[self.at..self.at + end];
        self.at += end;
        Some(name)
    }

    fn namespace(&self, prefix: &str) -> Option<&str> {
        for scope in self.scopes.iter().rev() {
            if let Some((_, uri)) = scope.iter().find(|(p, _)| p == prefix) {
                return Some(uri);
            }
        }
        match prefix {
            "" => Some(""),
            "xml" => Some("http://www.w3.org/XML/1998/namespace"),
            _ => None,
        }
    }

    /// "{uri}local" for a name in a namespace, "local" for one in none.
    fn qualify(&self, name: &str, attribute: bool) -> Option<String> {
        let (prefix, local) = name.split_once(':').unwrap_or(("", name));
        if attribute && prefix.is_empty() {
            return Some(local.to_string());
        }
        let uri = self.namespace(prefix)?;
        Some(if uri.is_empty() {
            local.to_string()
        } else {
            format!("{{{uri}}}{local}")
        })
    }

    fn element(&mut self, depth: usize) -> Option<Element> {
        if depth > 256 {
            return None;
        }
        self.at += 1; // '<'
        let raw_name = self.name()?.to_string();
        let mut raw_attrs: Vec<(String, String)> = Vec::new();
        let mut scope = Vec::new();
        let empty = loop {
            let before = self.at;
            self.skip_space();
            let rest = self.rest();
            if rest.starts_with("/>") {
                self.at += 2;
                break true;
            }
            if rest.starts_with('>') {
                self.at += 1;
                break false;
            }
            if self.at == before {
                return None; // an attribute with no space before it
            }
            let name = self.name()?.to_string();
            self.skip_space();
            if !self.rest().starts_with('=') {
                return None;
            }
            self.at += 1;
            self.skip_space();
            let q = self.rest().chars().next()?;
            if q != '"' && q != '\'' {
                return None;
            }
            self.at += 1;
            let raw = self.past(&q.to_string())?;
            if raw.contains('<') {
                return None;
            }
            let value: String = unescape(raw)?
                .chars()
                .map(|c| {
                    if matches!(c, '\t' | '\n' | '\r') {
                        ' '
                    } else {
                        c
                    }
                })
                .collect();
            if name == "xmlns" {
                scope.push((String::new(), value));
            } else if let Some(prefix) = name.strip_prefix("xmlns:") {
                scope.push((prefix.to_string(), value));
            } else {
                if raw_attrs.iter().any(|(k, _)| *k == name) {
                    return None;
                }
                raw_attrs.push((name, value));
            }
        };
        self.scopes.push(scope);
        let mut e = Element {
            tag: self.qualify(&raw_name, false)?,
            ..Default::default()
        };
        for (k, v) in raw_attrs {
            e.attrs.push((self.qualify(&k, true)?, v));
        }
        if !empty {
            self.content(&mut e, &raw_name, depth)?;
        }
        self.scopes.pop();
        Some(e)
    }

    fn content(&mut self, e: &mut Element, raw_name: &str, depth: usize) -> Option<()> {
        loop {
            let rest = self.rest();
            let lt = rest.find('<')?;
            if lt > 0 {
                let text = unescape(&rest[..lt])?;
                if e.children.is_empty() {
                    e.text.push_str(&text);
                }
                self.at += lt;
            }
            let rest = self.rest();
            if rest.starts_with("</") {
                self.at += 2;
                let name = self.name()?;
                if name != raw_name {
                    return None;
                }
                self.skip_space();
                if !self.rest().starts_with('>') {
                    return None;
                }
                self.at += 1;
                return Some(());
            } else if rest.starts_with("<!--") {
                self.past("-->")?;
            } else if rest.starts_with("<![CDATA[") {
                self.at += 9;
                let data = self.past("]]>")?.to_string();
                if e.children.is_empty() {
                    e.text.push_str(&data);
                }
            } else if rest.starts_with("<?") {
                self.past("?>")?;
            } else if rest.starts_with("<!") {
                return None;
            } else {
                let child = self.element(depth + 1)?;
                e.children.push(child);
            }
        }
    }
}

/// XML's five entities and character references decoded; none for an
/// entity it does not know, or a lone '&'.
pub fn unescape(raw: &str) -> Option<String> {
    if !raw.contains('&') {
        return Some(raw.to_string());
    }
    let mut out = String::with_capacity(raw.len());
    let mut rest = raw;
    while let Some(i) = rest.find('&') {
        out.push_str(&rest[..i]);
        rest = &rest[i + 1..];
        let end = rest.find(';')?;
        let entity = &rest[..end];
        rest = &rest[end + 1..];
        let ch = match entity {
            "lt" => '<',
            "gt" => '>',
            "amp" => '&',
            "apos" => '\'',
            "quot" => '"',
            _ => {
                let n = match (entity.strip_prefix("#x"), entity.strip_prefix('#')) {
                    (Some(hex), _) => u32::from_str_radix(hex, 16).ok()?,
                    (None, Some(dec)) => dec.parse().ok()?,
                    (None, None) => return None,
                };
                char::from_u32(n).filter(|c| *c != '\0')?
            }
        };
        out.push(ch);
    }
    out.push_str(rest);
    Some(out)
}

/// <text> for an element's content.
pub fn escape(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_multistatus_in_namespaces() {
        let doc = br#"<?xml version="1.0" encoding="utf-8"?>
<!-- a comment -->
<d:multistatus xmlns:d="DAV:" xmlns="urn:ietf:params:xml:ns:caldav">
  <d:response><d:href>/a%20b/</d:href>
    <d:propstat><d:prop><calendar-data><![CDATA[BEGIN:VCALENDAR
]]>&amp;x</calendar-data><d:resourcetype><d:collection/><calendar /></d:resourcetype>
    <comp name="VEVENT"/></d:prop></d:propstat>
  </d:response>
  <d:sync-token>tok&#x41;</d:sync-token>
</d:multistatus>"#;
        let root = parse(doc).unwrap();
        assert_eq!(root.tag, "{DAV:}multistatus");
        assert_eq!(root.findtext("{DAV:}sync-token"), Some("tokA"));
        let responses = root.iter("{DAV:}response");
        assert_eq!(responses.len(), 1);
        assert_eq!(responses[0].findtext("{DAV:}href"), Some("/a%20b/"));
        let prop = responses[0]
            .find("{DAV:}propstat")
            .unwrap()
            .find("{DAV:}prop")
            .unwrap();
        let data = prop
            .find("{urn:ietf:params:xml:ns:caldav}calendar-data")
            .unwrap();
        assert_eq!(data.text, "BEGIN:VCALENDAR\n&x");
        let rt = prop.find("{DAV:}resourcetype").unwrap();
        assert_eq!(rt.children.len(), 2);
        assert!(rt.find("{urn:ietf:params:xml:ns:caldav}calendar").is_some());
        let comp = prop.find("{urn:ietf:params:xml:ns:caldav}comp").unwrap();
        assert_eq!(comp.get("name"), Some("VEVENT"));
    }

    #[test]
    fn what_is_not_well_formed_is_refused() {
        assert!(parse(b"<a><b></a>").is_none());
        assert!(parse(b"<a>&nbsp;</a>").is_none());
        assert!(parse(b"<x:a/>").is_none());
        assert!(parse(b"<a/><b/>").is_none());
        assert!(parse(b"not xml").is_none());
        assert!(parse(b"<a>").is_none());
        assert!(parse(b"<a b='1' b='2'/>").is_none());
        assert!(parse(b"<a/>  ").is_some());
    }
}
