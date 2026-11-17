//! Just enough XML for AppStream catalogs: elements, attributes, text and
//! the five entities with character references, as a tree per element asked
//! for. Comments, processing instructions and the doctype are skipped;
//! CDATA is text. A catalog is a file the system or Flathub wrote, so a
//! malformed one ends the read with an error rather than a guess.

use std::fmt;

#[derive(Debug, PartialEq)]
pub struct Error {
    pub at: usize,
    pub what: &'static str,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{} at byte {}", self.what, self.at)
    }
}

/// An element: its name, its attributes, and what is in it in order.
#[derive(Debug, Default, PartialEq)]
pub struct Node {
    pub name: String,
    pub attrs: Vec<(String, String)>,
    pub children: Vec<Child>,
}

#[derive(Debug, PartialEq)]
pub enum Child {
    Element(Node),
    Text(String),
}

impl Node {
    pub fn attr(&self, name: &str) -> Option<&str> {
        self.attrs
            .iter()
            .find(|(k, _)| k == name)
            .map(|(_, v)| v.as_str())
    }

    pub fn elements(&self) -> impl Iterator<Item = &Node> {
        self.children.iter().filter_map(|c| match c {
            Child::Element(n) => Some(n),
            Child::Text(_) => None,
        })
    }

    pub fn all<'a>(&'a self, name: &'a str) -> impl Iterator<Item = &'a Node> + 'a {
        self.elements().filter(move |n| n.name == name)
    }

    pub fn first(&self, name: &str) -> Option<&Node> {
        self.elements().find(|n| n.name == name)
    }

    /// The text in it and in what it holds, in order, with each run of
    /// white space one space, and none at either end.
    pub fn text(&self) -> String {
        let mut raw = String::new();
        self.collect(&mut raw);
        squeeze(&raw)
    }

    fn collect(&self, out: &mut String) {
        for child in &self.children {
            match child {
                Child::Text(t) => out.push_str(t),
                Child::Element(n) => n.collect(out),
            }
        }
    }
}

pub fn squeeze(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Whether an element, by its name and attributes, is to be left out.
pub type Skip = dyn Fn(&str, &[(String, String)]) -> bool;

/// Reads elements out of a document. `next_element(name)` finds the next
/// element of that name at any depth and returns it whole; what `skip` says
/// is left out of it (translations, here) is never built.
pub struct Reader<'a> {
    s: &'a str,
    pos: usize,
}

enum Tag<'a> {
    Open {
        name: &'a str,
        attrs: Vec<(String, String)>,
        empty: bool,
    },
    Close(&'a str),
    Text(String),
}

impl<'a> Reader<'a> {
    pub fn new(s: &'a str) -> Self {
        Reader { s, pos: 0 }
    }

    fn err(&self, what: &'static str) -> Error {
        Error { at: self.pos, what }
    }

    fn rest(&self) -> &'a str {
        &self.s[self.pos..]
    }

    /// The next piece of the document, or None at its end.
    fn tag(&mut self) -> Result<Option<Tag<'a>>, Error> {
        loop {
            let rest = self.rest();
            if rest.is_empty() {
                return Ok(None);
            }
            if !rest.starts_with('<') {
                let end = rest.find('<').unwrap_or(rest.len());
                let raw = &rest[..end];
                self.pos += end;
                return Ok(Some(Tag::Text(
                    unescape(raw).map_err(|_| self.err("a bad entity"))?,
                )));
            }
            if rest.starts_with("<!--") {
                let end = rest
                    .find("-->")
                    .ok_or_else(|| self.err("an unclosed comment"))?;
                self.pos += end + 3;
                continue;
            }
            if rest.starts_with("<![CDATA[") {
                let end = rest
                    .find("]]>")
                    .ok_or_else(|| self.err("an unclosed CDATA section"))?;
                let text = rest[9..end].to_string();
                self.pos += end + 3;
                return Ok(Some(Tag::Text(text)));
            }
            if rest.starts_with("<?") {
                let end = rest
                    .find("?>")
                    .ok_or_else(|| self.err("an unclosed processing instruction"))?;
                self.pos += end + 2;
                continue;
            }
            if rest.starts_with("<!") {
                let end = rest
                    .find('>')
                    .ok_or_else(|| self.err("an unclosed declaration"))?;
                self.pos += end + 1;
                continue;
            }
            if let Some(after) = rest.strip_prefix("</") {
                let end = after
                    .find('>')
                    .ok_or_else(|| self.err("an unclosed end tag"))?;
                let name = after[..end].trim();
                self.pos += 2 + end + 1;
                return Ok(Some(Tag::Close(name)));
            }
            return self.open().map(Some);
        }
    }

    fn open(&mut self) -> Result<Tag<'a>, Error> {
        let s = self.s;
        let bytes = s.as_bytes();
        let mut i = self.pos + 1;
        let start = i;
        while i < bytes.len()
            && !bytes[i].is_ascii_whitespace()
            && bytes[i] != b'>'
            && bytes[i] != b'/'
        {
            i += 1;
        }
        let name = &s[start..i];
        if name.is_empty() {
            return Err(Error {
                at: i,
                what: "a tag without a name",
            });
        }
        let mut attrs = Vec::new();
        loop {
            while i < bytes.len() && bytes[i].is_ascii_whitespace() {
                i += 1;
            }
            match bytes.get(i) {
                None => {
                    return Err(Error {
                        at: i,
                        what: "an unclosed tag",
                    })
                }
                Some(b'>') => {
                    self.pos = i + 1;
                    return Ok(Tag::Open {
                        name,
                        attrs,
                        empty: false,
                    });
                }
                Some(b'/') if bytes.get(i + 1) == Some(&b'>') => {
                    self.pos = i + 2;
                    return Ok(Tag::Open {
                        name,
                        attrs,
                        empty: true,
                    });
                }
                Some(_) => {}
            }
            let key_start = i;
            while i < bytes.len()
                && bytes[i] != b'='
                && !bytes[i].is_ascii_whitespace()
                && bytes[i] != b'>'
            {
                i += 1;
            }
            let key = &s[key_start..i];
            while i < bytes.len() && bytes[i].is_ascii_whitespace() {
                i += 1;
            }
            if bytes.get(i) != Some(&b'=') {
                return Err(Error {
                    at: i,
                    what: "an attribute without a value",
                });
            }
            i += 1;
            while i < bytes.len() && bytes[i].is_ascii_whitespace() {
                i += 1;
            }
            let quote = match bytes.get(i) {
                Some(&q) if q == b'"' || q == b'\'' => q,
                _ => {
                    return Err(Error {
                        at: i,
                        what: "an unquoted attribute",
                    })
                }
            };
            i += 1;
            let value_start = i;
            while i < bytes.len() && bytes[i] != quote {
                i += 1;
            }
            if i >= bytes.len() {
                return Err(Error {
                    at: i,
                    what: "an unclosed attribute",
                });
            }
            let value = unescape(&s[value_start..i]).map_err(|_| Error {
                at: i,
                what: "a bad entity",
            })?;
            i += 1;
            attrs.push((key.to_string(), value));
        }
    }

    /// The next element called `name`, whole, at whatever depth; None at the
    /// end of the document. An element `skip` returns true for is left out
    /// of the tree, with all it holds.
    pub fn next_element(&mut self, name: &str, skip: &Skip) -> Result<Option<Node>, Error> {
        while let Some(tag) = self.tag()? {
            if let Tag::Open {
                name: n,
                attrs,
                empty,
            } = tag
            {
                if n == name {
                    let mut node = Node {
                        name: n.to_string(),
                        attrs,
                        children: Vec::new(),
                    };
                    if !empty {
                        self.fill(&mut node, skip)?;
                    }
                    return Ok(Some(node));
                }
            }
        }
        Ok(None)
    }

    fn fill(&mut self, node: &mut Node, skip: &Skip) -> Result<(), Error> {
        loop {
            match self.tag()? {
                None => return Err(self.err("an element that does not end")),
                Some(Tag::Text(t)) => node.children.push(Child::Text(t)),
                Some(Tag::Close(n)) => {
                    if n != node.name {
                        return Err(self.err("an end tag that does not match"));
                    }
                    return Ok(());
                }
                Some(Tag::Open { name, attrs, empty }) => {
                    if skip(name, &attrs) {
                        if !empty {
                            self.pass(name)?;
                        }
                        continue;
                    }
                    let mut child = Node {
                        name: name.to_string(),
                        attrs,
                        children: Vec::new(),
                    };
                    if !empty {
                        self.fill(&mut child, skip)?;
                    }
                    node.children.push(Child::Element(child));
                }
            }
        }
    }

    /// Past the end of the element just opened, building nothing.
    fn pass(&mut self, name: &str) -> Result<(), Error> {
        let mut depth = 1usize;
        while depth > 0 {
            match self.tag()? {
                None => return Err(self.err("an element that does not end")),
                Some(Tag::Open { empty: false, .. }) => depth += 1,
                Some(Tag::Close(n)) => {
                    depth -= 1;
                    if depth == 0 && n != name {
                        return Err(self.err("an end tag that does not match"));
                    }
                }
                Some(_) => {}
            }
        }
        Ok(())
    }
}

/// Text with &amp; &lt; &gt; &quot; &apos; and &#..; turned back into what
/// they stand for.
pub fn unescape(raw: &str) -> Result<String, ()> {
    if !raw.contains('&') {
        return Ok(raw.to_string());
    }
    let mut out = String::with_capacity(raw.len());
    let mut rest = raw;
    while let Some(at) = rest.find('&') {
        out.push_str(&rest[..at]);
        let after = &rest[at + 1..];
        let end = after.find(';').ok_or(())?;
        let entity = &after[..end];
        let ch = match entity {
            "amp" => '&',
            "lt" => '<',
            "gt" => '>',
            "quot" => '"',
            "apos" => '\'',
            _ => {
                let code = if let Some(hex) = entity
                    .strip_prefix("#x")
                    .or_else(|| entity.strip_prefix("#X"))
                {
                    u32::from_str_radix(hex, 16).map_err(|_| ())?
                } else if let Some(dec) = entity.strip_prefix('#') {
                    dec.parse::<u32>().map_err(|_| ())?
                } else {
                    return Err(());
                };
                char::from_u32(code).ok_or(())?
            }
        };
        out.push(ch);
        rest = &after[end + 1..];
    }
    out.push_str(rest);
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn none(_: &str, _: &[(String, String)]) -> bool {
        false
    }

    #[test]
    fn reads_elements_attributes_and_text() {
        let doc = r#"<?xml version="1.0"?>
<!-- a catalog -->
<components origin='x'>
  <component type="desktop-application">
    <id>org.example.App</id>
    <name>Tom &amp; Jerry &#x2014; &#39;Two&#39;</name>
    <description><p>One <em>bold</em> word.</p><p><![CDATA[a <b> c]]></p></description>
    <icon type="cached" width="64" height="64"/>
  </component>
</components>"#;
        let mut r = Reader::new(doc);
        let c = r.next_element("component", &none).unwrap().unwrap();
        assert_eq!(c.attr("type"), Some("desktop-application"));
        assert_eq!(c.first("id").unwrap().text(), "org.example.App");
        assert_eq!(
            c.first("name").unwrap().text(),
            "Tom & Jerry \u{2014} 'Two'"
        );
        let d = c.first("description").unwrap();
        let ps: Vec<String> = d.all("p").map(Node::text).collect();
        assert_eq!(ps, vec!["One bold word.", "a <b> c"]);
        assert_eq!(c.first("icon").unwrap().attr("width"), Some("64"));
        assert!(r.next_element("component", &none).unwrap().is_none());
    }

    #[test]
    fn leaves_out_what_skip_says() {
        let doc = r#"<c><name>A</name><name xml:lang="de"><b>B</b></name><name/></c>"#;
        let skip = |_: &str, attrs: &[(String, String)]| attrs.iter().any(|(k, _)| k == "xml:lang");
        let c = Reader::new(doc).next_element("c", &skip).unwrap().unwrap();
        let names: Vec<String> = c.all("name").map(Node::text).collect();
        assert_eq!(names, vec!["A", ""]);
    }

    #[test]
    fn says_where_a_document_is_broken() {
        let mut r = Reader::new("<a><b></a>");
        assert_eq!(
            r.next_element("a", &none).unwrap_err().what,
            "an end tag that does not match"
        );
        let mut r = Reader::new("<a x=1></a>");
        assert_eq!(
            r.next_element("a", &none).unwrap_err().what,
            "an unquoted attribute"
        );
        let mut r = Reader::new("<a>&nope;</a>");
        assert_eq!(r.next_element("a", &none).unwrap_err().what, "a bad entity");
        let mut r = Reader::new("<a><b>");
        assert_eq!(
            r.next_element("a", &none).unwrap_err().what,
            "an element that does not end"
        );
    }

    #[test]
    fn squeezes_white_space() {
        assert_eq!(squeeze("  a\n   b\tc  "), "a b c");
    }
}
