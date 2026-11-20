//! One calendar synced: what the server changed, merged into the file;
//! what this computer changed, sent. Three versions of each item are
//! compared: the server's, the file's, and the one both had at the last
//! sync (its "base"); "prev" is the base before the server's last change,
//! which a file written from before that change still has.

use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

use crate::dav::{check, href_key, multistatus, propfind, q, CALDAV, CS, DAV, NS};
use crate::digest::{hex, sha1, uuid4};
use crate::http::{Http, Response};
use crate::ical::{
    self, calendar_of, canon, groups, is_item, parse, parse_group, prop_name, same_group,
    serialize, set_line, timezones, value, zone_ids, Component, Group, STAMPS,
};
use crate::json::Json;
use crate::store::{load_state, read_file, save_state, swap_in, Entry, OMap, State};
use crate::xml::escape;
use crate::zone::{self, vtimezone};
use crate::{settings, url, Kind, SyncError};

/// A write refused because the item changed on the server meanwhile, or a
/// sync token the server no longer takes.
pub enum Failure {
    Precondition,
    Sync(SyncError),
}

impl From<SyncError> for Failure {
    fn from(e: SyncError) -> Failure {
        Failure::Sync(e)
    }
}

/// A calendar of more items than this losing more than half of them in one
/// sync is taken to be a broken file, not deletions.
const FEW: usize = 5;

/// A RECURRENCE-ID as the key of one time of an item, in UTC where its zone
/// is known, so both sides match whatever zone each wrote it in.
fn recurrence_key(c: &Component) -> String {
    match ical::get(c, "RECURRENCE-ID") {
        Some(p) => format!(
            "{}|{}",
            c.name,
            zone::instant(p.value, p.param("TZID"), p.param("VALUE") == Some("DATE"))
        ),
        None => format!("{}|", c.name),
    }
}

fn stamp() -> String {
    zone::format_stamp(crate::now() as i64) + "Z"
}

/// A property or a child component of one version of a component.
#[derive(Clone)]
enum Part {
    Line(String),
    Child(Component),
}

impl Part {
    fn key(&self) -> String {
        match self {
            Part::Line(l) => l.clone(),
            Part::Child(c) => canon(c),
        }
    }
}

fn eq(x: Option<&Component>, y: Option<&Component>) -> bool {
    match (x, y) {
        (None, None) => true,
        (Some(a), Some(b)) => canon(a) == canon(b),
        _ => false,
    }
}

/// The three versions of one component (an event, or one time of it):
/// the merged one (none: gone), or a conflict.
fn merge_component(
    b: Option<&Component>,
    l: Option<&Component>,
    r: Option<&Component>,
) -> Result<Option<Component>, ()> {
    if eq(l, r) || eq(l, b) {
        return Ok(r.cloned());
    }
    if eq(r, b) {
        return Ok(l.cloned());
    }
    let (Some(b), Some(l), Some(r)) = (b, l, r) else {
        return Err(());
    };
    fn parts(c: &Component) -> Vec<(String, Vec<Part>)> {
        let mut d: Vec<(String, Vec<Part>)> = Vec::new();
        let mut add = |name: String, p: Part| match d.iter_mut().find(|(n, _)| *n == name) {
            Some((_, v)) => v.push(p),
            None => d.push((name, vec![p])),
        };
        for line in &c.lines {
            add(prop_name(line), Part::Line(line.clone()));
        }
        for child in &c.children {
            add(format!("BEGIN:{}", child.name), Part::Child(child.clone()));
        }
        d
    }
    let find = |d: &[(String, Vec<Part>)], name: &str| -> Vec<Part> {
        d.iter()
            .find(|(n, _)| n == name)
            .map(|(_, v)| v.clone())
            .unwrap_or_default()
    };
    let keys = |v: &[Part]| v.iter().map(Part::key).collect::<Vec<_>>();
    let (pb, pl, pr) = (parts(b), parts(l), parts(r));
    let mut out = Component::new(&r.name, Vec::new(), Vec::new());
    let names: Vec<String> = pr
        .iter()
        .map(|(n, _)| n.clone())
        .chain(
            pl.iter()
                .map(|(n, _)| n.clone())
                .filter(|n| !pr.iter().any(|(m, _)| m == n)),
        )
        .collect();
    for name in names {
        if STAMPS.contains(&name.as_str()) {
            continue;
        }
        let (vb, vl, vr) = (find(&pb, &name), find(&pl, &name), find(&pr, &name));
        let chosen = if keys(&vl) == keys(&vr) || keys(&vl) == keys(&vb) {
            vr
        } else if keys(&vr) == keys(&vb) {
            vl
        } else {
            return Err(());
        };
        for p in chosen {
            match p {
                Part::Line(line) => out.lines.push(line),
                Part::Child(c) => out.children.push(c),
            }
        }
    }
    let now = stamp();
    out.lines.insert(0, format!("DTSTAMP:{now}"));
    out.lines.push(format!("LAST-MODIFIED:{now}"));
    let seqs: Vec<i64> = [value(l, "SEQUENCE"), value(r, "SEQUENCE")]
        .iter()
        .filter_map(|v| {
            let v = v.trim();
            (!v.is_empty() && v.bytes().all(|b| b.is_ascii_digit()))
                .then(|| v.parse().ok())
                .flatten()
        })
        .collect();
    if let Some(max) = seqs.iter().max() {
        out.lines.push(format!("SEQUENCE:{max}"));
    }
    Ok(Some(out))
}

/// An item changed here and on the server, merged; none where the two
/// changed the same thing differently.
fn merge_group(
    base: Option<&[Component]>,
    local: Option<&[Component]>,
    remote: Option<&[Component]>,
) -> Option<Group> {
    let by_key = |g: Option<&[Component]>| -> Vec<(String, Component)> {
        let mut out: Vec<(String, Component)> = Vec::new();
        for c in g.unwrap_or_default() {
            let k = recurrence_key(c);
            match out.iter_mut().find(|(key, _)| *key == k) {
                Some((_, v)) => *v = c.clone(),
                None => out.push((k, c.clone())),
            }
        }
        out
    };
    let (bb, ll, rr) = (by_key(base), by_key(local), by_key(remote));
    let get = |m: &[(String, Component)], k: &str| {
        m.iter().find(|(key, _)| key == k).map(|(_, c)| c.clone())
    };
    let keys: Vec<String> = rr
        .iter()
        .map(|(k, _)| k.clone())
        .chain(
            ll.iter()
                .map(|(k, _)| k.clone())
                .filter(|k| !rr.iter().any(|(m, _)| m == k)),
        )
        .collect();
    let mut out = Vec::new();
    for k in keys {
        let (b, l, r) = (get(&bb, &k), get(&ll, &k), get(&rr, &k));
        match merge_component(b.as_ref(), l.as_ref(), r.as_ref()) {
            Err(()) => return None,
            Ok(Some(c)) => out.push(c),
            Ok(None) => {}
        }
    }
    Some(out)
}

/// This computer's version of an item kept beside the server's: the same,
/// under a UID of its own.
fn copy_of(group: &[Component]) -> (String, Group) {
    let uid = format!("{}@nova", uuid4());
    let out = group
        .iter()
        .map(|c| {
            let mut copy = c.clone();
            set_line(&mut copy, "UID", &uid);
            copy
        })
        .collect();
    (uid, out)
}

fn resource_name(uid: &str) -> String {
    let plain = (1..=120).contains(&uid.chars().count())
        && uid
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'@' | b'-'));
    if plain {
        format!("{}.ics", url::quote(uid, "@"))
    } else {
        format!("{}.ics", hex(&sha1(uid.as_bytes())))
    }
}

/// One item fetched: its href, its ETag, its text.
type Fetched = OMap<(String, String, String)>;

fn opt(g: &Option<Group>) -> Option<&[Component]> {
    g.as_deref()
}

pub struct CalendarSync<'a> {
    http: Option<&'a mut Http>,
    cal: Json,
    path: PathBuf,
    pub state: State,
    pool: BTreeMap<String, Component>,
    pub pending: usize,
    error: Option<SyncError>,
}

impl<'a> CalendarSync<'a> {
    pub fn new(http: Option<&'a mut Http>, cal: &Json) -> CalendarSync<'a> {
        CalendarSync {
            http,
            cal: cal.clone(),
            path: settings().data_dir.join(cal.text("file")),
            state: load_state(cal.text("id")),
            pool: BTreeMap::new(),
            pending: 0,
            error: None,
        }
    }

    fn http(&mut self) -> &mut Http {
        self.http
            .as_deref_mut()
            .expect("a sync that talks to the server has its connection")
    }

    fn name(&self) -> String {
        self.cal.text("name").to_string()
    }

    fn href(&self) -> String {
        self.cal.text("href").to_string()
    }

    fn writable(&self) -> bool {
        !self.cal.is("readOnly")
    }

    fn entry_etag_differs(&self, k: &str, etag: &str) -> bool {
        match self.state.items.get(k) {
            None => true,
            Some(e) => etag.is_empty() || e.etag.as_deref() != Some(etag),
        }
    }

    /// What the server changed: {key: href} changed, the keys deleted.
    fn remote_changes(&mut self) -> Result<(OMap<String>, BTreeSet<String>), SyncError> {
        let href = self.href();
        if let Some(token) = self.state.text("token") {
            match self.sync_collection(&href, &token) {
                Ok(found) => return Ok(found),
                Err(Failure::Precondition) => {
                    self.state.fields.remove("token");
                }
                Err(Failure::Sync(e)) => return Err(e),
            }
        }
        let found = propfind(self.http(), &href, &["<d:sync-token/>", "<cs:getctag/>"], 0)?;
        let (new_token, ctag) = match found.first() {
            Some(f) => (
                f.props.text(&q(DAV, "sync-token")),
                f.props.text(&q(CS, "getctag")),
            ),
            None => (String::new(), String::new()),
        };
        if new_token.is_empty()
            && !ctag.is_empty()
            && self.state.text("ctag").as_deref() == Some(ctag.as_str())
            && !self.state.items.is_empty()
        {
            return Ok((OMap::new(), BTreeSet::new()));
        }
        let mut listing: OMap<(String, String)> = OMap::new();
        let own = href_key(&href);
        for f in propfind(
            self.http(),
            &href,
            &["<d:getetag/>", "<d:resourcetype/>"],
            1,
        )? {
            let collection = f
                .props
                .get(&q(DAV, "resourcetype"))
                .is_some_and(|rt| !rt.children.is_empty());
            if href_key(&f.href).trim_end_matches('/') == own.trim_end_matches('/') || collection {
                continue;
            }
            let etag = f.props.text(&q(DAV, "getetag"));
            listing.insert(&href_key(&f.href), (f.href, etag));
        }
        let mut changed = OMap::new();
        for (k, (h, etag)) in listing.iter() {
            if self.entry_etag_differs(k, etag) {
                changed.insert(k, h.clone());
            }
        }
        let deleted = self
            .state
            .items
            .keys()
            .into_iter()
            .filter(|k| !listing.contains(k))
            .collect();
        self.state
            .set("token", Some(new_token).filter(|t| !t.is_empty()));
        self.state.set("ctag", Some(ctag).filter(|t| !t.is_empty()));
        Ok((changed, deleted))
    }

    fn sync_collection(
        &mut self,
        href: &str,
        token: &str,
    ) -> Result<(OMap<String>, BTreeSet<String>), Failure> {
        let mut changed: OMap<String> = OMap::new();
        let mut deleted: BTreeSet<String> = BTreeSet::new();
        let mut token = token.to_string();
        let own = href_key(href);
        for _ in 0..50 {
            let body = format!(
                r#"<?xml version="1.0" encoding="utf-8"?><d:sync-collection {NS}><d:sync-token>{}</d:sync-token><d:sync-level>1</d:sync-level><d:prop><d:getetag/></d:prop></d:sync-collection>"#,
                escape(&token)
            );
            let resp = self.http().request(
                "REPORT",
                href,
                Some(&body),
                &[
                    ("Depth", "1"),
                    ("Content-Type", "application/xml; charset=utf-8"),
                ],
            )?;
            let mentions_token = resp.body.windows(10).any(|w| w == b"sync-token");
            if resp.status == 403 || resp.status == 409 || (resp.status == 400 && mentions_token) {
                return Err(Failure::Precondition);
            }
            if resp.status != 207 {
                check(&resp, false)?;
                return Err(Failure::Precondition);
            }
            let (responses, root) = multistatus(&resp)?;
            let mut more = false;
            for f in responses {
                let k = href_key(&f.href);
                if k.trim_end_matches('/') == own.trim_end_matches('/') {
                    more = more || f.status.contains(" 507");
                    continue;
                }
                if f.status.contains(" 404") || (f.props.is_empty() && !f.status.contains(" 200")) {
                    deleted.insert(k.clone());
                    changed.remove(&k);
                } else {
                    let etag = f.props.text(&q(DAV, "getetag"));
                    deleted.remove(&k);
                    if self.entry_etag_differs(&k, &etag) {
                        changed.insert(&k, f.href.clone());
                    }
                }
            }
            if let Some(t) = root
                .findtext(&q(DAV, "sync-token"))
                .filter(|t| !t.is_empty())
            {
                token = t.to_string();
            }
            if !more {
                break;
            }
        }
        self.state.set("token", Some(token));
        deleted.retain(|k| self.state.items.contains(k));
        Ok((changed, deleted))
    }

    /// The items at <hrefs>, by calendar-multiget, and the keys the server
    /// says are gone (404).
    fn fetch(&mut self, hrefs: &[String]) -> Result<(Fetched, BTreeSet<String>), SyncError> {
        let mut out = OMap::new();
        let mut gone = BTreeSet::new();
        let cal_href = self.href();
        for chunk in hrefs.chunks(100) {
            let refs: String = chunk
                .iter()
                .map(|h| {
                    format!(
                        "<d:href>{}</d:href>",
                        escape(&url::split(h).map(|s| s.path).unwrap_or_default())
                    )
                })
                .collect();
            let body = format!(
                r#"<?xml version="1.0" encoding="utf-8"?><c:calendar-multiget {NS}><d:prop><d:getetag/><c:calendar-data/></d:prop>{refs}</c:calendar-multiget>"#
            );
            let resp = self.http().request(
                "REPORT",
                &cal_href,
                Some(&body),
                &[
                    ("Depth", "1"),
                    ("Content-Type", "application/xml; charset=utf-8"),
                ],
            )?;
            if resp.status != 207 {
                check(&resp, false)?;
            }
            for f in multistatus(&resp)?.0 {
                match f.props.get(&q(CALDAV, "calendar-data")) {
                    Some(data) if !data.text.is_empty() => {
                        let etag = f.props.text(&q(DAV, "getetag"));
                        out.insert(
                            &href_key(&f.href),
                            (f.href.clone(), etag, data.text.clone()),
                        );
                    }
                    _ if f.status.contains(" 404") => {
                        gone.insert(href_key(&f.href));
                    }
                    _ => {}
                }
            }
        }
        Ok((out, gone))
    }

    /// An item's ETag and text; none when it is not there.
    fn get(&mut self, href: &str) -> Result<Option<(Option<String>, String)>, SyncError> {
        let resp = self
            .http()
            .request("GET", href, None, &[("Accept", "text/calendar")])?;
        if resp.status == 404 {
            return Ok(None);
        }
        if resp.status != 200 {
            check(&resp, false)?;
        }
        Ok(Some((resp.header("etag").map(str::to_string), resp.text())))
    }

    /// The item in a resource's text: its UID and its components.
    fn remote_group(&mut self, text: &str) -> Option<(String, Group)> {
        let mut root = parse(text);
        let cal = calendar_of(&mut root);
        for (k, v) in timezones(cal) {
            self.pool.entry(k).or_insert(v);
        }
        groups(cal).into_iter().next()
    }

    fn build_resource(&mut self, group: &[Component]) -> String {
        let mut comps = Vec::new();
        for tzid in zone_ids(group) {
            if let Some(tz) = self.zone_for(&tzid) {
                comps.push(tz);
            }
        }
        comps.extend(group.iter().cloned());
        let cal = Component::new(
            "VCALENDAR",
            vec!["VERSION:2.0".into(), "PRODID:-//Nova//Calendar//EN".into()],
            comps,
        );
        serialize(&[cal])
    }

    fn zone_for(&mut self, tzid: &str) -> Option<Component> {
        if let Some(z) = self.pool.get(tzid) {
            return Some(z.clone());
        }
        let z = vtimezone(tzid)?;
        self.pool.insert(tzid.to_string(), z.clone());
        Some(z)
    }

    fn put(
        &mut self,
        href: &str,
        group: &[Component],
        etag: Option<&str>,
    ) -> Result<(Option<String>, Option<String>), Failure> {
        let body = self.build_resource(group);
        let cond = match etag.filter(|e| !e.is_empty()) {
            Some(e) => ("If-Match", e.to_string()),
            None => ("If-None-Match", "*".to_string()),
        };
        let resp: Response = self.http().request(
            "PUT",
            href,
            Some(&body),
            &[
                ("Content-Type", "text/calendar; charset=utf-8"),
                (cond.0, &cond.1),
            ],
        )?;
        if resp.status == 412 {
            return Err(Failure::Precondition);
        }
        if !matches!(resp.status, 200 | 201 | 204) {
            if resp.status == 401 || resp.status == 403 {
                return Err(SyncError::error(format!(
                    "The server refused a change to {}.",
                    self.name()
                ))
                .into());
            }
            check(&resp, true)?;
        }
        if let Some(new) = resp
            .header("etag")
            .filter(|e| !e.is_empty() && !e.starts_with("W/"))
        {
            return Ok((Some(new.to_string()), None));
        }
        // No ETag: the server changed what it was sent; what it keeps is
        // read back.
        Ok(match self.get(href)? {
            Some((etag, text)) => (etag, Some(text)),
            None => (None, None),
        })
    }

    fn delete(&mut self, href: &str, etag: Option<&str>) -> Result<(), Failure> {
        let headers: Vec<(&str, &str)> = match etag.filter(|e| !e.is_empty()) {
            Some(e) => vec![("If-Match", e)],
            None => Vec::new(),
        };
        let resp = self.http().request("DELETE", href, None, &headers)?;
        if resp.status == 412 {
            return Err(Failure::Precondition);
        }
        if !matches!(resp.status, 200 | 204 | 404) {
            check(&resp, true)?;
        }
        Ok(())
    }

    pub fn run(&mut self) -> Result<(), SyncError> {
        let before = (
            self.state.fields.get("token").cloned(),
            self.state.fields.get("ctag").cloned(),
        );
        let (changed, mut deleted) = self.remote_changes()?;
        let (mut fetched, gone) = if changed.is_empty() {
            (OMap::new(), BTreeSet::new())
        } else {
            let hrefs: Vec<String> = changed.values().cloned().collect();
            self.fetch(&hrefs)?
        };
        deleted.extend(gone.iter().cloned());
        if changed
            .iter()
            .any(|(k, _)| !fetched.contains(k) && !gone.contains(k))
        {
            // An item the server left out of its answer stays as it is
            // here, and is asked for again at the next sync.
            self.state
                .fields
                .set("token", before.0.unwrap_or(Json::Null));
            self.state
                .fields
                .set("ctag", before.1.unwrap_or(Json::Null));
        }
        let file_error = |name: String| {
            SyncError::error(format!("The file of {name} could not be read or written."))
        };
        let mut text = read_file(&self.path).map_err(|_| file_error(self.name()))?;
        for _ in 0..6 {
            let merged = self.merge(text.as_deref(), &fetched, &deleted)?;
            fetched = OMap::new();
            deleted = BTreeSet::new();
            if text.as_deref() == Some(merged.as_str()) {
                break;
            }
            match swap_in(&self.path, &merged, text.as_deref())
                .map_err(|_| file_error(self.name()))?
            {
                Some(newer) => text = Some(newer),
                None => break,
            }
        }
        save_state(self.cal.text("id"), &self.state).map_err(|_| file_error(self.name()))?;
        match self.error.take() {
            Some(e) => Err(e),
            None => Ok(()),
        }
    }

    fn merge(
        &mut self,
        text: Option<&str>,
        fetched: &Fetched,
        deleted: &BTreeSet<String>,
    ) -> Result<String, SyncError> {
        let mut root = parse(text.unwrap_or(""));
        let damaged = !root.children.iter().any(|c| c.name == "VCALENDAR");
        let cal = calendar_of(&mut root);
        for c in cal.children.iter_mut() {
            if is_item(c) && ical::uid(c).is_empty() {
                set_line(c, "UID", &format!("{}@nova", uuid4())); // sent as a new item
            }
        }
        let cal = cal.clone();
        let mut local: OMap<Group> = OMap::new();
        for (uid, g) in groups(&cal) {
            local.insert(&uid, g);
        }
        for (k, v) in timezones(&cal) {
            self.pool.entry(k).or_insert(v);
        }
        let mut result: OMap<Group> = local.clone();
        let mut by_uid: OMap<String> = OMap::new();
        for (k, e) in self.state.items.iter() {
            by_uid.insert(&e.uid, k.to_string());
        }
        let writable = self.writable();

        // The server's changes, merged into the file's.
        for (k, (href, etag, data)) in fetched.iter() {
            let Some((uid, remote)) = self.remote_group(data) else {
                continue;
            };
            let entry = self.state.items.get(k).cloned();
            if entry.is_none() {
                if let Some(old) = by_uid.get(&uid).filter(|old| old.as_str() != k).cloned() {
                    // The same item at another address: the old one is gone.
                    self.state.items.remove(&old);
                }
            }
            let base = entry.as_ref().and_then(|e| parse_group(e.base.as_deref()));
            let mine = local.get(&uid).cloned();
            if mine.is_none() && entry.is_some() && same_group(Some(&remote), opt(&base)) {
                // Deleted here, and unchanged there but for its ETag.
                if let Some(e) = self.state.items.get_mut(k) {
                    e.etag = Some(etag.clone());
                }
                continue;
            }
            let prev = entry.as_ref().and_then(|e| parse_group(e.prev.as_deref()));
            let take_remote = match &mine {
                None => true,
                Some(m) => {
                    same_group(Some(m), opt(&base))
                        || same_group(Some(m), Some(&remote))
                        || (entry.is_some() && same_group(Some(m), opt(&prev)))
                }
            };
            if take_remote || !writable {
                result.insert(&uid, remote.clone());
            } else {
                match merge_group(opt(&base), mine.as_deref(), Some(&remote)) {
                    None => {
                        result.insert(&uid, remote.clone());
                        let (copy_uid, copy) = copy_of(mine.as_deref().unwrap_or_default());
                        result.insert(&copy_uid, copy);
                    }
                    Some(both) => result.insert(&uid, both),
                }
            }
            self.state.items.insert(
                k,
                Entry {
                    href: href.clone(),
                    uid: uid.clone(),
                    etag: Some(etag.clone()),
                    base: Some(serialize(&remote)),
                    prev: entry.and_then(|e| e.base),
                },
            );
            by_uid.insert(&uid, k.to_string());
        }
        for k in deleted {
            let Some(entry) = self.state.items.remove(k) else {
                continue;
            };
            by_uid.remove(&entry.uid);
            let mine = result.get(&entry.uid);
            let base = parse_group(entry.base.as_deref());
            let prev = parse_group(entry.prev.as_deref());
            let drop = match mine {
                None => true,
                Some(m) => {
                    same_group(Some(m), opt(&base)) || !writable || same_group(Some(m), opt(&prev))
                }
            };
            if drop {
                result.remove(&entry.uid);
            }
            // Else changed here: it stays, and is sent again as a new item.
        }

        // A file gone, emptied, or with most of its items gone at once is
        // more likely broken than edited: nothing is sent, and what it lost
        // comes back as the server has it.
        let lost: Vec<Entry> = self
            .state
            .items
            .values()
            .filter(|e| !result.contains(&e.uid))
            .cloned()
            .collect();
        let n = self.state.items.len();
        if writable && !lost.is_empty() && (damaged || (n > FEW && 2 * lost.len() > n)) {
            for e in &lost {
                result.insert(&e.uid, parse_group(e.base.as_deref()).unwrap_or_default());
            }
            let mut known: OMap<Entry> = OMap::new();
            for e in self.state.items.values() {
                known.insert(&e.uid, e.clone());
            }
            self.pending = result
                .iter()
                .filter(|(u, g)| match known.get(u) {
                    None => true,
                    Some(e) => !same_group(Some(g), opt(&parse_group(e.base.as_deref()))),
                })
                .count();
            self.error = Some(SyncError::error(format!(
                "Most of {} was missing on this computer. It was not deleted on the server, and is back.",
                self.name()
            )));
            return Ok(self.write(&cal, &result, &local));
        }

        // This computer's changes, sent.
        self.pending = 0;
        for uid in result.keys() {
            let k = by_uid.get(&uid).cloned().filter(|k| !k.is_empty());
            let entry = k.as_deref().and_then(|k| self.state.items.get(k)).cloned();
            let group = result.get(&uid).cloned().unwrap_or_default();
            if let Some(e) = &entry {
                let base = parse_group(e.base.as_deref());
                if same_group(Some(&group), opt(&base)) {
                    if same_group(local.get(&uid).map(|g| g.as_slice()), opt(&base)) {
                        // The file has had the server's change.
                        if let Some(e) = self
                            .state
                            .items
                            .get_mut(k.as_deref().expect("an entry has a key"))
                        {
                            e.prev = None;
                        }
                    }
                    continue;
                }
                if same_group(Some(&group), opt(&parse_group(e.prev.as_deref()))) || !writable {
                    // The file was written from before the server's change.
                    result.insert(&uid, base.unwrap_or_default());
                    continue;
                }
            } else if !writable {
                result.remove(&uid);
                continue;
            }
            let k = if entry.is_some() { k } else { None };
            self.send(&uid, group, k, &mut result, &mut by_uid)?;
        }
        for (k, entry) in self
            .state
            .items
            .iter()
            .map(|(k, e)| (k.to_string(), e.clone()))
            .collect::<Vec<_>>()
        {
            if result.contains(&entry.uid) {
                continue;
            }
            if !writable {
                result.insert(
                    &entry.uid,
                    parse_group(entry.base.as_deref()).unwrap_or_default(),
                );
                continue;
            }
            match self.delete(&entry.href, entry.etag.as_deref()) {
                Ok(()) => {
                    self.state.items.remove(&k);
                }
                Err(Failure::Precondition) => {
                    // Changed there meanwhile: the change wins.
                    match self.get(&entry.href)? {
                        None => {
                            self.state.items.remove(&k);
                        }
                        Some((etag, text)) => {
                            let remote =
                                self.remote_group(&text).map(|(_, g)| g).unwrap_or_default();
                            result.insert(&entry.uid, remote.clone());
                            if let Some(e) = self.state.items.get_mut(&k) {
                                e.etag = etag;
                                e.base = Some(serialize(&remote));
                                e.prev = None;
                            }
                        }
                    }
                }
                Err(Failure::Sync(e)) => {
                    self.pending += 1;
                    if e.kind != Kind::Offline {
                        self.error = Some(e);
                    }
                }
            }
        }
        Ok(self.write(&cal, &result, &local))
    }

    /// The changes made here that the server has not had.
    pub fn count_pending(&self) -> std::io::Result<usize> {
        let mut root = parse(&read_file(&self.path)?.unwrap_or_default());
        let local = groups(calendar_of(&mut root));
        let mut by_uid: OMap<Entry> = OMap::new();
        for e in self.state.items.values() {
            by_uid.insert(&e.uid, e.clone());
        }
        let changed = local
            .iter()
            .filter(|(u, g)| match by_uid.get(u) {
                None => true,
                Some(e) => !same_group(Some(g), opt(&parse_group(e.base.as_deref()))),
            })
            .count();
        let removed = by_uid
            .keys()
            .iter()
            .filter(|u| !local.iter().any(|(l, _)| l == *u))
            .count();
        Ok(changed + removed)
    }

    /// A new entry for an item sent to <href>; its key.
    fn register(&mut self, href: &str, uid: &str, by_uid: &mut OMap<String>) -> String {
        let k = href_key(href);
        self.state.items.insert(&k, Entry::new(href, uid));
        by_uid.insert(uid, k.clone());
        k
    }

    /// An item new or changed here, sent; a refusal because it changed on
    /// the server meanwhile is merged and tried again.
    fn send(
        &mut self,
        uid: &str,
        mut group: Group,
        mut entry: Option<String>,
        result: &mut OMap<Group>,
        by_uid: &mut OMap<String>,
    ) -> Result<(), SyncError> {
        let mut name = resource_name(uid);
        let cal_href = self.href();
        for _ in 0..4 {
            let attempt = match &entry {
                None => {
                    let href = url::join(&cal_href, &name);
                    self.put(&href, &group, None).map(|r| (r, Some(href)))
                }
                Some(k) => {
                    let e = self
                        .state
                        .items
                        .get(k)
                        .cloned()
                        .expect("a registered entry");
                    self.put(&e.href, &group, e.etag.as_deref())
                        .map(|r| (r, None))
                }
            };
            match attempt {
                Ok(((etag, kept), new_href)) => {
                    if let Some(href) = new_href {
                        entry = Some(self.register(&href, uid, by_uid));
                    }
                    if let Some(kept) = kept {
                        group = self.remote_group(&kept).map(|(_, g)| g).unwrap_or_default();
                        result.insert(uid, group.clone());
                    }
                    let k = entry.as_deref().expect("registered above");
                    if let Some(e) = self.state.items.get_mut(k) {
                        e.etag = etag;
                        e.base = Some(serialize(&group));
                        e.prev = None;
                    }
                    return Ok(());
                }
                Err(Failure::Precondition) => {
                    let href = match &entry {
                        Some(k) => self
                            .state
                            .items
                            .get(k)
                            .map(|e| e.href.clone())
                            .unwrap_or_default(),
                        None => url::join(&cal_href, &name),
                    };
                    let Some((etag, text)) = self.get(&href)? else {
                        // Deleted there meanwhile: the change made here
                        // wins, as a new item.
                        if let Some(k) = entry.take() {
                            if let Some(e) = self.state.items.get(&k) {
                                let key = href_key(&e.href);
                                self.state.items.remove(&key);
                            }
                        }
                        continue;
                    };
                    let (remote_uid, remote) = self.remote_group(&text).unwrap_or_default();
                    if entry.is_none() && remote_uid != uid {
                        // Another item has the address: this one takes another.
                        name = format!("{}.ics", uuid4());
                        continue;
                    }
                    let k = match entry.clone() {
                        Some(k) => k,
                        None => {
                            let k = self.register(&href, uid, by_uid);
                            entry = Some(k.clone());
                            k
                        }
                    };
                    let base = self
                        .state
                        .items
                        .get(&k)
                        .and_then(|e| parse_group(e.base.as_deref()));
                    let both = merge_group(opt(&base), Some(&group), Some(&remote));
                    if let Some(e) = self.state.items.get_mut(&k) {
                        e.etag = etag;
                        e.base = Some(serialize(&remote));
                        e.prev = None;
                    }
                    match both {
                        None => {
                            result.insert(uid, remote.clone());
                            let (copy_uid, copy) = copy_of(&group);
                            result.insert(&copy_uid, copy.clone());
                            return self.send(&copy_uid, copy, None, result, by_uid);
                        }
                        Some(both) => {
                            result.insert(uid, both.clone());
                            let done = same_group(Some(&both), Some(&remote));
                            group = both;
                            if done {
                                return Ok(());
                            }
                        }
                    }
                }
                Err(Failure::Sync(e)) => {
                    // Not sent: it stays as it is here, and is tried again
                    // at the next sync.
                    self.pending += 1;
                    if e.kind != Kind::Offline {
                        self.error = Some(e);
                    }
                    return Ok(());
                }
            }
        }
        Ok(())
    }

    /// The file as the merge left it: its own lines, the zones its items
    /// name, and its items, in the order they were.
    fn write(&mut self, cal: &Component, result: &OMap<Group>, local: &OMap<Group>) -> String {
        let mut items: Vec<Component> = Vec::new();
        let order: Vec<String> = local
            .keys()
            .into_iter()
            .chain(result.keys().into_iter().filter(|u| !local.contains(u)))
            .collect();
        for uid in order {
            if let Some(g) = result.get(&uid) {
                items.extend(g.iter().cloned());
            }
        }
        let mut zones = Vec::new();
        for tzid in zone_ids(&items) {
            if let Some(tz) = self.zone_for(&tzid) {
                zones.push(tz);
            }
        }
        let mut head: Vec<String> = cal
            .lines
            .iter()
            .filter(|l| matches!(prop_name(l).as_str(), "VERSION" | "PRODID" | "CALSCALE"))
            .cloned()
            .collect();
        if head.is_empty() {
            head = vec!["VERSION:2.0".into(), "PRODID:-//Nova//Calendar//EN".into()];
        }
        let others = cal
            .children
            .iter()
            .filter(|c| !is_item(c) && c.name != "VTIMEZONE")
            .cloned();
        let mut children = zones;
        children.extend(others);
        children.extend(items);
        serialize(&[Component::new("VCALENDAR", head, children)])
    }
}
