//! iCalendar as Ical.js keeps it, and the shell with it: components and
//! their lines, unfolded, each kept as it was read.

use std::collections::BTreeSet;

#[derive(Debug, Clone, PartialEq, Default)]
pub struct Component {
    pub name: String,
    pub lines: Vec<String>,
    pub children: Vec<Component>,
}

impl Component {
    pub fn new(name: &str, lines: Vec<String>, children: Vec<Component>) -> Component {
        Component {
            name: name.to_string(),
            lines,
            children,
        }
    }
}

/// An item: an event, a task or a journal, and the times of it moved on
/// their own, under one UID.
pub type Group = Vec<Component>;

pub const ITEMS: [&str; 3] = ["VEVENT", "VTODO", "VJOURNAL"];

pub fn is_item(c: &Component) -> bool {
    ITEMS.contains(&c.name.as_str())
}

pub fn unfold(text: &str) -> String {
    let text = text.replace("\r\n", "\n").replace('\r', "\n");
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\n' && matches!(chars.peek(), Some(' ' | '\t')) {
            chars.next();
            continue;
        }
        out.push(c);
    }
    out
}

/// A property's parts: its name upper-cased, its parameters (names
/// upper-cased, values without their quotes), and its value.
pub struct Prop<'a> {
    pub name: String,
    pub params: Vec<(String, String)>,
    pub value: &'a str,
}

impl Prop<'_> {
    pub fn param(&self, name: &str) -> Option<&str> {
        // The last of a name twice, as a dict keeps it.
        self.params
            .iter()
            .rev()
            .find(|(k, _)| k == name)
            .map(|(_, v)| v.as_str())
    }
}

/// NAME;PARAM=value:value, or none without a colon outside quotes.
pub fn split_line(line: &str) -> Option<Prop<'_>> {
    let mut quoted = false;
    let mut colon = None;
    for (i, c) in line.char_indices() {
        if c == '"' {
            quoted = !quoted;
        } else if c == ':' && !quoted {
            colon = Some(i);
            break;
        }
    }
    let colon = colon?;
    let mut parts = Vec::new();
    let mut part = String::new();
    let mut quoted = false;
    for c in line[..colon].chars() {
        if c == '"' {
            quoted = !quoted;
        }
        if c == ';' && !quoted {
            parts.push(std::mem::take(&mut part));
        } else {
            part.push(c);
        }
    }
    parts.push(part);
    let mut params = Vec::new();
    for p in &parts[1..] {
        let Some((key, value)) = p.split_once('=') else {
            continue;
        };
        let value = if value.len() >= 2 && value.starts_with('"') && value.ends_with('"') {
            &value[1..value.len() - 1]
        } else {
            value
        };
        params.push((key.to_uppercase(), value.to_string()));
    }
    Some(Prop {
        name: parts[0].to_uppercase(),
        params,
        value: &line[colon + 1..],
    })
}

pub fn prop_name(line: &str) -> String {
    let end = line.find([';', ':']).unwrap_or(line.len());
    line[..end].to_uppercase()
}

/// The components of <text>, under a root with no name.
pub fn parse(text: &str) -> Component {
    let mut stack = vec![Component::default()];
    for line in unfold(text).split('\n') {
        if line.is_empty() {
            continue;
        }
        let Some(p) = split_line(line) else {
            continue;
        };
        if p.name == "BEGIN" {
            stack.push(Component::new(
                &p.value.trim().to_uppercase(),
                Vec::new(),
                Vec::new(),
            ));
        } else if p.name == "END" {
            if stack.len() > 1 {
                let done = stack.pop().expect("more than the root");
                stack.last_mut().expect("the root").children.push(done);
            }
        } else {
            stack
                .last_mut()
                .expect("the root")
                .lines
                .push(line.to_string());
        }
    }
    // Components never ended are kept, as the reader kept them.
    while stack.len() > 1 {
        let done = stack.pop().expect("more than the root");
        stack.last_mut().expect("the root").children.push(done);
    }
    stack.pop().expect("the root")
}

/// A line folded at 75 octets, the lines after the first at 74 and a space.
pub fn fold(line: &str) -> String {
    let mut out: Vec<String> = Vec::new();
    let mut current = String::new();
    let mut size = 0;
    for ch in line.chars() {
        let n = ch.len_utf8();
        if size + n > if out.is_empty() { 75 } else { 74 } {
            out.push(std::mem::take(&mut current));
            size = 0;
        }
        current.push(ch);
        size += n;
    }
    out.push(current);
    out.join("\r\n ")
}

fn serialize_into(c: &Component, out: &mut Vec<String>) {
    out.push(format!("BEGIN:{}", c.name));
    out.extend(c.lines.iter().map(|l| fold(l)));
    for child in &c.children {
        serialize_into(child, out);
    }
    out.push(format!("END:{}", c.name));
}

pub fn serialize(components: &[Component]) -> String {
    let mut out = Vec::new();
    for c in components {
        serialize_into(c, &mut out);
    }
    if out.is_empty() {
        String::new()
    } else {
        out.join("\r\n") + "\r\n"
    }
}

pub fn get<'a>(c: &'a Component, name: &str) -> Option<Prop<'a>> {
    c.lines
        .iter()
        .find(|line| prop_name(line) == name)
        .and_then(|line| split_line(line))
}

pub fn value<'a>(c: &'a Component, name: &str) -> &'a str {
    get(c, name).map_or("", |p| p.value)
}

/// The first line of <name> replaced, or one added; the others go.
pub fn set_line(c: &mut Component, name: &str, text: &str) {
    let mut at = None;
    let mut kept = Vec::with_capacity(c.lines.len() + 1);
    for line in c.lines.drain(..) {
        if prop_name(&line) == name {
            if at.is_none() {
                at = Some(kept.len());
            }
            continue;
        }
        kept.push(line);
    }
    let line = format!("{name}:{text}");
    match at {
        Some(i) => kept.insert(i, line),
        None => kept.push(line),
    }
    c.lines = kept;
}

pub fn unescape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\\' {
            match chars.peek() {
                Some('n' | 'N') => {
                    chars.next();
                    out.push('\n');
                    continue;
                }
                Some(&e @ ('\\' | ';' | ',')) => {
                    chars.next();
                    out.push(e);
                    continue;
                }
                _ => {}
            }
        }
        out.push(c);
    }
    out
}

/// The UID of an item, unescaped and trimmed.
pub fn uid(c: &Component) -> String {
    unescape(value(c, "UID")).trim().to_string()
}

/// The VCALENDAR of a root, one made and added where it has none.
pub fn calendar_of(root: &mut Component) -> &mut Component {
    let at = match root.children.iter().position(|c| c.name == "VCALENDAR") {
        Some(i) => i,
        None => {
            root.children.push(Component::new(
                "VCALENDAR",
                vec!["VERSION:2.0".into(), "PRODID:-//Nova//Calendar//EN".into()],
                Vec::new(),
            ));
            root.children.len() - 1
        }
    };
    &mut root.children[at]
}

/// The items of a calendar by their UID, in the order they first come.
pub fn groups(cal: &Component) -> Vec<(String, Group)> {
    let mut out: Vec<(String, Group)> = Vec::new();
    for c in cal.children.iter().filter(|c| is_item(c)) {
        let uid = uid(c);
        if uid.is_empty() {
            continue;
        }
        match out.iter_mut().find(|(u, _)| *u == uid) {
            Some((_, g)) => g.push(c.clone()),
            None => out.push((uid, vec![c.clone()])),
        }
    }
    out
}

/// The VTIMEZONEs of a calendar by their TZID.
pub fn timezones(cal: &Component) -> Vec<(String, Component)> {
    let mut out: Vec<(String, Component)> = Vec::new();
    for c in cal.children.iter().filter(|c| c.name == "VTIMEZONE") {
        if value(c, "TZID").is_empty() {
            continue;
        }
        let id = unescape(value(c, "TZID"));
        match out.iter_mut().find(|(k, _)| *k == id) {
            Some((_, z)) => *z = c.clone(),
            None => out.push((id, c.clone())),
        }
    }
    out
}

/// What a change stamps, which two versions differing only in are the same.
pub const STAMPS: [&str; 3] = ["DTSTAMP", "LAST-MODIFIED", "SEQUENCE"];

/// A component as text to compare, without its stamps.
pub fn canon(c: &Component) -> String {
    let mut parts = vec![format!("BEGIN:{}", c.name)];
    parts.extend(
        c.lines
            .iter()
            .filter(|l| !STAMPS.contains(&prop_name(l).as_str()))
            .cloned(),
    );
    parts.extend(c.children.iter().map(canon));
    parts.push(format!("END:{}", c.name));
    parts.join("\n")
}

pub fn group_canon(group: Option<&[Component]>) -> Option<String> {
    let group = group.filter(|g| !g.is_empty())?;
    let mut all: Vec<String> = group.iter().map(canon).collect();
    all.sort();
    Some(all.join("\n"))
}

pub fn same_group(a: Option<&[Component]>, b: Option<&[Component]>) -> bool {
    group_canon(a) == group_canon(b)
}

/// The items in a resource's text; none for no text.
pub fn parse_group(text: Option<&str>) -> Option<Group> {
    let text = text.filter(|t| !t.is_empty())?;
    Some(parse(text).children.into_iter().filter(is_item).collect())
}

/// The TZIDs the lines of <components> name, sorted.
pub fn zone_ids(components: &[Component]) -> BTreeSet<String> {
    let mut out = BTreeSet::new();
    fn walk(c: &Component, out: &mut BTreeSet<String>) {
        for line in &c.lines {
            if let Some(p) = split_line(line) {
                if let Some(tz) = p.param("TZID").filter(|t| !t.is_empty()) {
                    out.insert(tz.to_string());
                }
            }
        }
        for child in &c.children {
            walk(child, out);
        }
    }
    for c in components {
        walk(c, &mut out);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn read_and_written_back() {
        let text = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:a\\,b\r\nSUMMARY;LANGUAGE=\"x;y:z\":Hi: there\r\nDESCRIPTION:long\r\n  folded\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
        let mut root = parse(text);
        let cal = calendar_of(&mut root);
        let g = groups(cal);
        assert_eq!(g.len(), 1);
        assert_eq!(g[0].0, "a,b");
        let ev = &g[0].1[0];
        let p = get(ev, "SUMMARY").unwrap();
        assert_eq!(p.param("LANGUAGE"), Some("x;y:z"));
        assert_eq!(p.value, "Hi: there");
        assert_eq!(value(ev, "DESCRIPTION"), "long folded");
        let back = serialize(&root.children);
        assert!(back.contains("DESCRIPTION:long folded\r\n"));
    }

    #[test]
    fn long_lines_fold_at_75_octets() {
        let line = format!("SUMMARY:{}", "é".repeat(60));
        let folded = fold(&line);
        for (i, part) in folded.split("\r\n").enumerate() {
            assert!(part.len() <= 75, "{i}: {}", part.len());
        }
        assert_eq!(unfold(&folded), line);
    }

    #[test]
    fn set_line_keeps_the_place() {
        let mut c = Component::new(
            "VEVENT",
            vec!["A:1".into(), "UID:x".into(), "B:2".into(), "UID:y".into()],
            vec![],
        );
        set_line(&mut c, "UID", "z");
        assert_eq!(c.lines, vec!["A:1", "UID:z", "B:2"]);
        set_line(&mut c, "C", "3");
        assert_eq!(c.lines.last().unwrap(), "C:3");
    }

    #[test]
    fn groups_compare_without_their_stamps() {
        let a = parse_group(Some(
            "BEGIN:VEVENT\nUID:1\nDTSTAMP:1\nSUMMARY:x\nEND:VEVENT\n",
        ))
        .unwrap();
        let b = parse_group(Some(
            "BEGIN:VEVENT\nUID:1\nDTSTAMP:2\nSUMMARY:x\nEND:VEVENT\n",
        ))
        .unwrap();
        assert!(same_group(Some(&a), Some(&b)));
        assert!(same_group(None, Some(&[])));
        assert!(!same_group(None, Some(&a)));
    }
}
