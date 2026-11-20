//! Time zones from the system's zone database (TZif files): a local time in
//! a TZID as UTC, to match a RECURRENCE-ID whatever zone each side wrote it
//! in, and a VTIMEZONE for a zone a file names without one. Read as
//! Python's zoneinfo reads them, so a time in a gap or a fold of the clock
//! comes out as it always did: the earlier of two, the offset before a gap.

use crate::ical::Component;

/// Where the zone database is, in the order zoneinfo looks.
const TZPATH: [&str; 4] = [
    "/usr/share/zoneinfo",
    "/usr/lib/zoneinfo",
    "/usr/share/lib/zoneinfo",
    "/etc/zoneinfo",
];

// ---- the calendar

pub fn is_leap(y: i64) -> bool {
    (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
}

pub fn month_days(y: i64, m: i64) -> i64 {
    match m {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        _ if is_leap(y) => 29,
        _ => 28,
    }
}

/// Days from 1970-01-01 to <y>-<m>-<d>.
pub fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe - 719468
}

pub fn civil_from_days(z: i64) -> (i64, i64, i64) {
    let z = z + 719468;
    let era = z.div_euclid(146097);
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (if m <= 2 { y + 1 } else { y }, m, d)
}

/// Sunday 0 to Saturday 6.
pub fn weekday(days: i64) -> i64 {
    (days + 4).rem_euclid(7)
}

/// Seconds since 1970 as YYYYMMDDTHHMMSS.
pub fn format_stamp(seconds: i64) -> String {
    let (y, m, d) = civil_from_days(seconds.div_euclid(86400));
    let s = seconds.rem_euclid(86400);
    format!(
        "{y:04}{m:02}{d:02}T{:02}{:02}{:02}",
        s / 3600,
        s / 60 % 60,
        s % 60
    )
}

// ---- POSIX TZ strings, the rule after the last change a file lists

#[derive(Debug, Clone, Copy, PartialEq)]
enum Day {
    /// Mm.w.d: the w-th weekday d of month m, 5 the last.
    Month(i64, i64, i64),
    /// Jn: day n of the year, 1 to 365, never Feb 29.
    Julian(i64),
    /// n: day n of the year from 0, Feb 29 counted.
    Zero(i64),
}

#[derive(Debug, Clone, Copy, PartialEq)]
struct Rule {
    day: Day,
    /// Seconds after local midnight; can be negative or past a day.
    at: i64,
}

impl Rule {
    /// The local time of the change in <year>, in seconds since 1970.
    fn local(&self, year: i64) -> i64 {
        let days = match self.day {
            Day::Julian(n) => {
                let mut d = days_from_civil(year, 1, 1) + n - 1;
                if is_leap(year) && n >= 60 {
                    d += 1;
                }
                d
            }
            Day::Zero(n) => days_from_civil(year, 1, 1) + n,
            Day::Month(m, w, wd) => {
                let first = days_from_civil(year, m, 1);
                let first_wd = weekday(first);
                let mut day = first + (wd - first_wd).rem_euclid(7) + 7 * (w - 1);
                if w == 5 {
                    while day >= first + month_days(year, m) {
                        day -= 7;
                    }
                }
                day
            }
        };
        days * 86400 + self.at
    }
}

#[derive(Debug, Clone, PartialEq)]
struct TzStr {
    std: i64,
    dst: Option<(i64, Rule, Rule)>,
    std_dst: bool,
}

/// "[+-]h[:mm[:ss]]", hours to 167 for a rule's time.
fn hms(text: &str, max_hours: i64) -> Option<i64> {
    let (sign, rest) = match text.as_bytes().first()? {
        b'+' => (1, &text[1..]),
        b'-' => (-1, &text[1..]),
        _ => (1, text),
    };
    let mut parts = rest.split(':');
    let h = parts.next()?;
    if h.is_empty() || h.len() > 3 || !h.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let mut seconds = h.parse::<i64>().ok()?;
    if seconds > max_hours {
        return None;
    }
    seconds *= 3600;
    for (i, part) in parts.enumerate() {
        if i > 1 || part.len() != 2 || !part.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        seconds += part.parse::<i64>().ok()? * if i == 0 { 60 } else { 1 };
    }
    Some(sign * seconds)
}

/// A zone's name in a TZ string: letters, or anything in <...>; how long.
fn tz_name(s: &str) -> Option<usize> {
    if let Some(rest) = s.strip_prefix('<') {
        let end = rest.find('>')?;
        let inner = &rest[..end];
        (!inner.is_empty()
            && inner
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'+' || b == b'-'))
        .then_some(end + 2)
    } else {
        let end = s
            .find(|c: char| c.is_ascii_digit() || matches!(c, ':' | '.' | '+' | '-' | ','))
            .unwrap_or(s.len());
        (end > 0).then_some(end)
    }
}

fn tz_offset(s: &str) -> usize {
    s.find(|c: char| !(c.is_ascii_digit() || matches!(c, ':' | '+' | '-')))
        .unwrap_or(s.len())
}

fn parse_rule(text: &str) -> Option<Rule> {
    let (day, at) = match text.split_once('/') {
        Some((d, t)) => (d, hms(t, 167)?),
        None => (text, 7200),
    };
    let day = if let Some(m) = day.strip_prefix('M') {
        let mut p = m.split('.');
        let (Some(m), Some(w), Some(d), None) = (p.next(), p.next(), p.next(), p.next()) else {
            return None;
        };
        let (m, w, d): (i64, i64, i64) = (m.parse().ok()?, w.parse().ok()?, d.parse().ok()?);
        if !(1..=12).contains(&m) || !(1..=5).contains(&w) || !(0..=6).contains(&d) {
            return None;
        }
        Day::Month(m, w, d)
    } else if let Some(n) = day.strip_prefix('J') {
        let n: i64 = n.parse().ok()?;
        if !(1..=365).contains(&n) {
            return None;
        }
        Day::Julian(n)
    } else {
        let n: i64 = day.parse().ok()?;
        if !(0..=365).contains(&n) {
            return None;
        }
        Day::Zero(n)
    };
    Some(Rule { day, at })
}

fn parse_tz_str(text: &str) -> Option<TzStr> {
    let (zone, rules) = match text.split_once(',') {
        Some((z, r)) => (z, Some(r)),
        None => (text, None),
    };
    let n = tz_name(zone)?;
    let rest = &zone[n..];
    let o = tz_offset(rest);
    let std = -hms(&rest[..o], 24)?;
    let rest = &rest[o..];
    if rest.is_empty() {
        return (rules.is_none()).then_some(TzStr {
            std,
            dst: None,
            std_dst: false,
        });
    }
    let n = tz_name(rest)?;
    let rest = &rest[n..];
    let dst = if rest.is_empty() {
        std + 3600
    } else {
        -hms(rest, 24)?
    };
    let (start, end) = rules?.split_once(',')?;
    Some(TzStr {
        std,
        dst: Some((dst, parse_rule(start)?, parse_rule(end)?)),
        std_dst: false,
    })
}

impl TzStr {
    /// The offset and whether it is daylight time, at a UTC instant.
    fn at_utc(&self, ts: i64) -> (i64, bool) {
        let Some((dst, start, end)) = &self.dst else {
            return (self.std, self.std_dst);
        };
        let year = civil_from_days(ts.div_euclid(86400)).0;
        let s = start.local(year) - self.std;
        let e = end.local(year) - dst;
        let isdst = if s < e {
            s <= ts && ts < e
        } else {
            !(e <= ts && ts < s)
        };
        if isdst {
            (*dst, true)
        } else {
            (self.std, false)
        }
    }

    /// The offset of a local time, the earlier where the clock goes back.
    fn at_local(&self, ts: i64) -> i64 {
        let Some((dst, start, end)) = &self.dst else {
            return self.std;
        };
        let year = civil_from_days(ts.div_euclid(86400)).0;
        let (mut s, mut e) = (start.local(year), end.local(year));
        let diff = dst - self.std;
        if diff >= 0 {
            s += diff;
        } else {
            e -= diff;
        }
        let isdst = if s < e {
            s <= ts && ts < e
        } else {
            !(e <= ts && ts < s)
        };
        if isdst {
            *dst
        } else {
            self.std
        }
    }
}

// ---- TZif

#[derive(Debug, Clone)]
pub struct Zone {
    /// UTC instants of the changes, and the type each changes to.
    trans: Vec<i64>,
    trans_types: Vec<usize>,
    /// The changes in local time, each at the later of the two offsets.
    trans_wall: Vec<i64>,
    types: Vec<(i64, bool)>,
    before: (i64, bool),
    after: After,
}

#[derive(Debug, Clone)]
enum After {
    Fixed((i64, bool)),
    Rule(TzStr),
}

fn be32(b: &[u8], at: usize) -> Option<i64> {
    Some(i32::from_be_bytes(b.get(at..at + 4)?.try_into().ok()?) as i64)
}

fn be64(b: &[u8], at: usize) -> Option<i64> {
    Some(i64::from_be_bytes(b.get(at..at + 8)?.try_into().ok()?))
}

/// A name of the zone database, or none for one that cannot be.
fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.split('/').all(|part| {
            !part.is_empty()
                && part
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'+' | b'-'))
        })
}

fn read_tzif(name: &str) -> Option<Vec<u8>> {
    if !valid_name(name) {
        return None;
    }
    for base in TZPATH {
        let path = format!("{base}/{name}");
        match std::fs::metadata(&path) {
            Ok(m) if m.is_file() => return std::fs::read(&path).ok(),
            Ok(_) => return None,
            Err(_) => continue,
        }
    }
    None
}

impl Zone {
    pub fn load(name: &str) -> Option<Zone> {
        Zone::from_bytes(&read_tzif(name)?)
    }

    fn from_bytes(data: &[u8]) -> Option<Zone> {
        if !data.starts_with(b"TZif") {
            return None;
        }
        let counts = |at: usize| -> Option<[usize; 6]> {
            let mut c = [0; 6];
            for (i, v) in c.iter_mut().enumerate() {
                *v = be32(data, at + 20 + 4 * i)? as usize;
            }
            Some(c)
        };
        let [isutc, isstd, leap, time, typ, chars] = counts(0)?;
        let version = data[4];
        let (base, width, footer_at) = if version >= b'2' {
            let v1 = 44 + time * 5 + typ * 6 + chars + leap * 8 + isstd + isutc;
            let [isutc, isstd, leap, time2, typ2, chars2] = counts(v1)?;
            let body = v1 + 44;
            let end = body + time2 * 9 + typ2 * 6 + chars2 + leap * 12 + isstd + isutc;
            (body, (time2, typ2, 8), Some(end))
        } else {
            (44, (time, typ, 4), None)
        };
        let (time, typ, size) = width;
        let mut trans = Vec::with_capacity(time);
        for i in 0..time {
            trans.push(if size == 8 {
                be64(data, base + i * 8)?
            } else {
                be32(data, base + i * 4)?
            });
        }
        let idx_at = base + time * size;
        let trans_types: Vec<usize> = data
            .get(idx_at..idx_at + time)?
            .iter()
            .map(|b| *b as usize)
            .collect();
        let types_at = idx_at + time;
        let mut types = Vec::with_capacity(typ);
        for i in 0..typ {
            let at = types_at + i * 6;
            types.push((be32(data, at)?, *data.get(at + 4)? != 0));
        }
        if types.is_empty() || trans_types.iter().any(|t| *t >= types.len()) {
            return None;
        }
        let footer = footer_at.and_then(|at| {
            let rest = data.get(at..)?;
            let rest = rest.strip_prefix(b"\n")?;
            let end = rest.iter().position(|b| *b == b'\n')?;
            Some(String::from_utf8_lossy(&rest[..end]).into_owned())
        });
        let after = match footer.filter(|f| !f.is_empty()) {
            Some(f) => After::Rule(parse_tz_str(&f)?),
            None => After::Fixed(
                trans_types
                    .last()
                    .map_or(*types.last().expect("not empty"), |t| types[*t]),
            ),
        };
        let before = types
            .iter()
            .find(|(_, dst)| !dst)
            .copied()
            .unwrap_or_else(|| trans_types.first().map_or(types[0], |t| types[*t]));
        let mut trans_wall = Vec::with_capacity(trans.len());
        for (i, t) in trans.iter().enumerate() {
            let prev = if i == 0 {
                types[0].0
            } else {
                types[trans_types[i - 1]].0
            };
            let next = types[trans_types[i]].0;
            trans_wall.push(t + prev.max(next));
        }
        Some(Zone {
            trans,
            trans_types,
            trans_wall,
            types,
            before,
            after,
        })
    }

    /// The offset at a UTC instant, and whether it is daylight time.
    pub fn at_utc(&self, ts: i64) -> (i64, bool) {
        if !self.trans.is_empty() && ts < self.trans[0] {
            return self.before;
        }
        if self.trans.is_empty() || ts > *self.trans.last().expect("not empty") {
            return match &self.after {
                After::Rule(r) => r.at_utc(ts),
                After::Fixed(t) => *t,
            };
        }
        let idx = self.trans.partition_point(|t| *t <= ts);
        self.types[self.trans_types[idx - 1]]
    }

    /// The offset of a local time, as zoneinfo reads one with fold 0.
    pub fn offset_of_local(&self, ts: i64) -> i64 {
        if !self.trans_wall.is_empty() && ts < self.trans_wall[0] {
            return self.before.0;
        }
        if self.trans_wall.is_empty() || ts > *self.trans_wall.last().expect("not empty") {
            return match &self.after {
                After::Rule(r) => r.at_local(ts),
                After::Fixed(t) => t.0,
            };
        }
        let idx = self.trans_wall.partition_point(|t| *t <= ts);
        self.types[self.trans_types[idx - 1]].0
    }
}

/// The zone a TZID names: itself, or its last two parts where it has more
/// (/mozilla.org/20050126_1/Europe/Rome, as some programs write them).
pub fn zone(tzid: &str) -> Option<Zone> {
    if tzid.is_empty() {
        return None;
    }
    let mut names = vec![tzid.to_string()];
    let parts: Vec<&str> = tzid.trim_matches('/').split('/').collect();
    if parts.len() > 2 {
        names.push(parts[parts.len() - 2..].join("/"));
    }
    names.iter().find_map(|n| Zone::load(n))
}

/// Year, month and day, and hour, minute, second and whether it is UTC.
type DateTime = (i64, i64, i64, Option<(i64, i64, i64, bool)>);

/// Digits for the date and time of a DATE-TIME, or none.
fn date_time(v: &str) -> Option<DateTime> {
    let b = v.as_bytes();
    let digits = |r: std::ops::Range<usize>| -> Option<i64> {
        let s = v.get(r)?;
        s.bytes()
            .all(|c| c.is_ascii_digit())
            .then(|| s.parse().ok())?
    };
    if b.len() != 8 && b.len() != 15 && b.len() != 16 {
        return None;
    }
    let date = (digits(0..4)?, digits(4..6)?, digits(6..8)?);
    if b.len() == 8 {
        return Some((date.0, date.1, date.2, None));
    }
    if b[8] != b'T' || (b.len() == 16 && b[15] != b'Z') {
        return None;
    }
    let time = (
        digits(9..11)?,
        digits(11..13)?,
        digits(13..15)?,
        b.len() == 16,
    );
    Some((date.0, date.1, date.2, Some(time)))
}

/// A DATE-TIME as UTC where its zone is known; else as written.
pub fn instant(text: &str, tzid: Option<&str>, value_date: bool) -> String {
    let v = text.trim();
    let Some((y, mo, d, Some((h, mi, s, z)))) = date_time(v) else {
        return v.to_string();
    };
    if value_date {
        return v.to_string();
    }
    if !(1..=9999).contains(&y)
        || !(1..=12).contains(&mo)
        || d < 1
        || d > month_days(y, mo)
        || h > 23
        || mi > 59
        || s > 59
    {
        return v.to_string();
    }
    if z {
        return v.to_string();
    }
    let Some(tz) = tzid.and_then(zone) else {
        return v.to_string();
    };
    let local = days_from_civil(y, mo, d) * 86400 + h * 3600 + mi * 60 + s;
    format_stamp(local - tz.offset_of_local(local)) + "Z"
}

// ---- VTIMEZONE

/// "+0100", "-0330", "+053028": an offset as iCalendar writes it.
pub fn utc_offset(seconds: i64) -> String {
    let sign = if seconds < 0 { '-' } else { '+' };
    let s = seconds.abs();
    let mut text = format!("{sign}{:02}{:02}", s / 3600, s / 60 % 60);
    if s % 60 != 0 {
        text.push_str(&format!("{:02}", s % 60));
    }
    text
}

/// "[+-]h[h[h]][:mm][:ss]" as seconds.
fn posix_offset(text: &str) -> Option<i64> {
    let (neg, rest) = match text.as_bytes().first()? {
        b'+' => (false, &text[1..]),
        b'-' => (true, &text[1..]),
        _ => (false, text),
    };
    let mut parts = rest.split(':');
    let h = parts.next()?;
    if h.is_empty() || h.len() > 3 || !h.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let mut seconds = h.parse::<i64>().ok()? * 3600;
    for (i, part) in parts.enumerate() {
        if i > 1 || part.len() != 2 || !part.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        seconds += part.parse::<i64>().ok()? * if i == 0 { 60 } else { 1 };
    }
    Some(if neg { -seconds } else { seconds })
}

/// "Mm.w.d[/time]" as (month, week, weekday, seconds).
fn posix_rule(text: &str) -> Option<(i64, i64, i64, i64)> {
    let rest = text.strip_prefix('M')?;
    let (day, at) = match rest.split_once('/') {
        Some((d, t)) if !t.is_empty() => (d, posix_offset(t)?),
        Some(_) => return None,
        None => (rest, 7200),
    };
    let mut p = day.split('.');
    let (Some(m), Some(w), Some(d), None) = (p.next(), p.next(), p.next(), p.next()) else {
        return None;
    };
    let ok = |s: &str, max: usize| {
        !s.is_empty() && s.len() <= max && s.bytes().all(|b| b.is_ascii_digit())
    };
    if !ok(m, 2) || !ok(w, 1) || !ok(d, 1) {
        return None;
    }
    Some((m.parse().ok()?, w.parse().ok()?, d.parse().ok()?, at))
}

/// The day of the month of the <week>-th <weekday> (5: the last).
fn rule_day(year: i64, month: i64, week: i64, weekday_: i64) -> Option<i64> {
    let days: Vec<i64> = (1..=month_days(year, month))
        .filter(|d| weekday(days_from_civil(year, month, *d)) == weekday_)
        .collect();
    match week {
        5 | 0 => days.last().copied(),
        1..=4 => days.get(week as usize - 1).copied(),
        _ => None,
    }
}

/// The TZ string a zone file ends with, read as the sync always read it.
fn tzif_footer(tzid: &str) -> Option<String> {
    let data = read_tzif(tzid)?;
    if !data.starts_with(b"TZif") || data.get(4).is_none_or(|v| *v < b'2') {
        return None;
    }
    let mut end = data.len();
    while end > 0 && data[end - 1] == b'\n' {
        end -= 1;
    }
    let start = data[..end]
        .iter()
        .rposition(|b| *b == b'\n')
        .map_or(0, |i| i + 1);
    Some(
        data[start..end]
            .iter()
            .map(|b| if b.is_ascii() { *b as char } else { '\u{FFFD}' })
            .collect(),
    )
}

/// A TZ string as (std name, std offset, dst name, dst offset, start, end),
/// the parts the VTIMEZONE needs.
struct Footer<'a> {
    std_name: &'a str,
    std_off: &'a str,
    dst_name: Option<&'a str>,
    dst_off: Option<&'a str>,
    rules: Option<(&'a str, &'a str)>,
}

fn footer_name(s: &str) -> Option<usize> {
    if let Some(rest) = s.strip_prefix('<') {
        let end = rest.find('>')?;
        (end > 0).then_some(end + 2)
    } else {
        let end = s
            .find(|c: char| !c.is_ascii_alphabetic())
            .unwrap_or(s.len());
        (end >= 3).then_some(end)
    }
}

fn footer_offset(s: &str) -> usize {
    s.find(|c: char| c.is_ascii_alphabetic() || c == '<' || c == ',')
        .unwrap_or(s.len())
}

fn parse_footer(f: &str) -> Option<Footer<'_>> {
    let n = footer_name(f)?;
    let std_name = &f[..n];
    let rest = &f[n..];
    let o = footer_offset(rest);
    if o == 0 {
        return None;
    }
    let std_off = &rest[..o];
    let rest = &rest[o..];
    let mut out = Footer {
        std_name,
        std_off,
        dst_name: None,
        dst_off: None,
        rules: None,
    };
    if rest.is_empty() {
        return Some(out);
    }
    let n = footer_name(rest)?;
    out.dst_name = Some(&rest[..n]);
    let rest = &rest[n..];
    let o = footer_offset(rest);
    if o > 0 {
        out.dst_off = Some(&rest[..o]);
    }
    let rest = &rest[o..];
    if rest.is_empty() {
        return Some(out);
    }
    let rules = rest.strip_prefix(',')?;
    let (a, b) = rules.split_once(',')?;
    if a.is_empty() || b.is_empty() || b.contains(',') {
        return None;
    }
    out.rules = Some((a, b));
    Some(out)
}

const DAYS: [&str; 7] = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"];

/// A VTIMEZONE for a zone of the database: its present rule, as other
/// calendar programs write them; or, for a rule a yearly RRULE cannot say,
/// each change from 1970 to 2050.
pub fn vtimezone(tzid: &str) -> Option<Component> {
    let footer = tzif_footer(tzid)?;
    let mut c = Component::new("VTIMEZONE", vec![format!("TZID:{tzid}")], Vec::new());
    let part = |c: &mut Component,
                kind: &str,
                start: String,
                frm: i64,
                to: i64,
                name: &str,
                extra: Vec<String>| {
        let mut lines = vec![
            format!("TZOFFSETFROM:{}", utc_offset(frm)),
            format!("TZOFFSETTO:{}", utc_offset(to)),
            format!("TZNAME:{}", name.trim_matches(['<', '>'])),
            format!("DTSTART:{start}"),
        ];
        lines.extend(extra);
        c.children.push(Component::new(kind, lines, Vec::new()));
    };
    if let Some(f) = parse_footer(&footer) {
        let std = posix_offset(f.std_off).map(|o| -o);
        if f.dst_name.is_none() {
            if let Some(std) = std {
                part(
                    &mut c,
                    "STANDARD",
                    "19700101T000000".into(),
                    std,
                    std,
                    f.std_name,
                    Vec::new(),
                );
                return Some(c);
            }
        } else if let (Some(std), Some((a, b)), Some(dst_name)) = (std, f.rules, f.dst_name) {
            let dst = match f.dst_off {
                Some(o) => posix_offset(o).map(|o| -o),
                None => Some(std + 3600),
            };
            if let (Some(dst), Some(begin), Some(end)) = (dst, posix_rule(a), posix_rule(b)) {
                if [begin, end].iter().all(|r| (0..86400).contains(&r.3)) {
                    let mut parts = Vec::new();
                    for (kind, rule, frm, to, name) in [
                        ("DAYLIGHT", begin, std, dst, dst_name),
                        ("STANDARD", end, dst, std, f.std_name),
                    ] {
                        let (month, week, wd, at) = rule;
                        let (Some(day), Some(dayname)) =
                            (rule_day(1970, month, week, wd), DAYS.get(wd as usize))
                        else {
                            parts.clear();
                            break;
                        };
                        let byday = format!(
                            "{}{dayname}",
                            if week == 5 {
                                "-1".to_string()
                            } else {
                                week.to_string()
                            }
                        );
                        let start = format!(
                            "1970{month:02}{day:02}T{:02}{:02}{:02}",
                            at / 3600,
                            at / 60 % 60,
                            at % 60
                        );
                        parts.push((
                            kind,
                            start,
                            frm,
                            to,
                            name,
                            vec![format!("RRULE:FREQ=YEARLY;BYMONTH={month};BYDAY={byday}")],
                        ));
                    }
                    if parts.len() == 2 {
                        for (kind, start, frm, to, name, extra) in parts {
                            part(&mut c, kind, start, frm, to, name, extra);
                        }
                        return Some(c);
                    }
                }
            }
        }
    }
    scanned_vtimezone(tzid)
}

/// Each change of a zone from 1970 to 2050, found six hours at a time and
/// then to the minute.
fn scanned_vtimezone(tzid: &str) -> Option<Component> {
    let tz = zone(tzid)?;
    let mut c = Component::new("VTIMEZONE", vec![format!("TZID:{tzid}")], Vec::new());
    // (from, to, daylight) and the local times it begins at, in order.
    let mut observances: Vec<((i64, i64, bool), Vec<String>)> = Vec::new();
    let mut at: i64 = 0;
    let end = days_from_civil(2050, 1, 1) * 86400;
    let (mut before, dst) = tz.at_utc(at);
    observances.push(((before, before, dst), vec!["19700101T000000".into()]));
    let step = 6 * 3600 * 1_000_000_i64;
    let mut at_us = at * 1_000_000;
    let offset_us = |us: i64| tz.at_utc(us.div_euclid(1_000_000)).0;
    while at < end {
        let next = at_us + step;
        let off = offset_us(next);
        if off != before {
            let (mut lo, mut hi) = (at_us, next);
            while hi - lo > 60_000_000 {
                let mid = lo + (hi - lo) / 2;
                if offset_us(mid) == before {
                    lo = mid;
                } else {
                    hi = mid;
                }
            }
            let hi_s = hi.div_euclid(1_000_000);
            let hi_s = hi_s - hi_s.rem_euclid(60);
            let wall = format_stamp(hi_s + before);
            let key = (before, off, tz.at_utc(hi_s).1);
            match observances.iter_mut().find(|(k, _)| *k == key) {
                Some((_, walls)) => walls.push(wall),
                None => observances.push((key, vec![wall])),
            }
            before = off;
        }
        at_us = next;
        at = at_us / 1_000_000;
    }
    for ((frm, to, daylight), walls) in observances {
        let mut lines = vec![
            format!("TZOFFSETFROM:{}", utc_offset(frm)),
            format!("TZOFFSETTO:{}", utc_offset(to)),
            format!("DTSTART:{}", walls[0]),
        ];
        lines.extend(walls[1..].iter().map(|w| format!("RDATE:{w}")));
        c.children.push(Component::new(
            if daylight { "DAYLIGHT" } else { "STANDARD" },
            lines,
            Vec::new(),
        ));
    }
    Some(c)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn days_and_back() {
        for (y, m, d) in [
            (1970, 1, 1),
            (2000, 2, 29),
            (2026, 11, 20),
            (1900, 3, 1),
            (2100, 12, 31),
        ] {
            assert_eq!(civil_from_days(days_from_civil(y, m, d)), (y, m, d));
        }
        assert_eq!(days_from_civil(1970, 1, 1), 0);
        assert_eq!(weekday(0), 4); // a Thursday
        assert_eq!(format_stamp(1795123987), "20261119T213307");
    }

    #[test]
    fn rome_in_and_out_of_summer_time() {
        let Some(rome) = zone("Europe/Rome") else {
            return; // no zone database here
        };
        assert_eq!(
            instant("20260115T100000", Some("Europe/Rome"), false),
            "20260115T090000Z"
        );
        assert_eq!(
            instant("20260715T100000", Some("Europe/Rome"), false),
            "20260715T080000Z"
        );
        // In the gap of 29 March: the offset before it.
        assert_eq!(
            instant("20260329T023000", Some("Europe/Rome"), false),
            "20260329T013000Z"
        );
        // In the fold of 25 October: the first of the two, summer time.
        assert_eq!(
            instant("20261025T023000", Some("Europe/Rome"), false),
            "20261025T003000Z"
        );
        // Far ahead, from the file's rule.
        assert_eq!(
            instant("20990715T100000", Some("Europe/Rome"), false),
            "20990715T080000Z"
        );
        assert_eq!(
            instant("20260715T100000", Some("/mozilla.org/x/Europe/Rome"), false),
            "20260715T080000Z"
        );
        assert_eq!(
            instant("20260715T100000Z", Some("Europe/Rome"), false),
            "20260715T100000Z"
        );
        assert_eq!(instant("20260715", Some("Europe/Rome"), false), "20260715");
        assert_eq!(
            instant("20260715T100000", Some("Nowhere/Here"), false),
            "20260715T100000"
        );
        assert_eq!(
            instant("20260715T100000", Some("Europe/Rome"), true),
            "20260715T100000"
        );
        assert_eq!(
            rome.at_utc(days_from_civil(2026, 7, 1) * 86400),
            (7200, true)
        );
        assert_eq!(
            rome.at_utc(days_from_civil(2090, 1, 1) * 86400),
            (3600, false)
        );
    }

    #[test]
    fn a_rule_as_rrules() {
        if zone("Europe/Rome").is_none() {
            return;
        }
        let tz = vtimezone("Europe/Rome").unwrap();
        let text = crate::ical::serialize(&[tz]);
        assert_eq!(
            text,
            "BEGIN:VTIMEZONE\r\nTZID:Europe/Rome\r\nBEGIN:DAYLIGHT\r\nTZOFFSETFROM:+0100\r\nTZOFFSETTO:+0200\r\nTZNAME:CEST\r\n\
             DTSTART:19700329T020000\r\nRRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU\r\nEND:DAYLIGHT\r\nBEGIN:STANDARD\r\n\
             TZOFFSETFROM:+0200\r\nTZOFFSETTO:+0100\r\nTZNAME:CET\r\nDTSTART:19701025T030000\r\n\
             RRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU\r\nEND:STANDARD\r\nEND:VTIMEZONE\r\n"
        );
        let tokyo = crate::ical::serialize(&[vtimezone("Asia/Tokyo").unwrap()]);
        assert!(tokyo.contains("BEGIN:STANDARD\r\nTZOFFSETFROM:+0900\r\nTZOFFSETTO:+0900\r\nTZNAME:JST\r\nDTSTART:19700101T000000\r\n"));
        assert!(vtimezone("Nowhere/Here").is_none());
        assert!(vtimezone("../etc/passwd").is_none());
    }

    #[test]
    fn tz_strings() {
        let eu = parse_tz_str("CET-1CEST,M3.5.0,M10.5.0/3").unwrap();
        assert_eq!(eu.std, 3600);
        let (dst, start, end) = eu.dst.unwrap();
        assert_eq!(dst, 7200);
        assert_eq!(
            start,
            Rule {
                day: Day::Month(3, 5, 0),
                at: 7200
            }
        );
        assert_eq!(end.at, 3 * 3600);
        assert!(parse_tz_str("<+0330>-3:30").is_some());
        assert!(parse_tz_str("<-02>2<-01>,M3.5.0/-1,M10.5.0/0").is_some());
        assert!(parse_tz_str("EST5EDT").is_none());
        assert_eq!(posix_offset("-3:30"), Some(-12600));
        assert_eq!(utc_offset(-12600), "-0330");
        assert_eq!(utc_offset(19800 + 28), "+053028");
    }
}
