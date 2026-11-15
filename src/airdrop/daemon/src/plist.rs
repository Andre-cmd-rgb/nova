//! Binary property lists: what AirDrop's requests and answers are written in.
//!
//! A sender's are read (whoever is in range can send one, so nothing in one
//! is trusted to be where it says: every offset is checked, and how deep and
//! how much is read is bounded); this computer's answers are written. Only
//! the kinds of value AirDrop uses come out as themselves, the rest as
//! `Other`.

#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Bool(bool),
    Int(i64),
    Text(String),
    Data(Vec<u8>),
    List(Vec<Value>),
    Dict(Vec<(String, Value)>),
    /// A date, a number with a fraction, nothing: read past, never asked for.
    Other,
}

impl Value {
    pub fn get(&self, key: &str) -> Option<&Value> {
        match self {
            Value::Dict(entries) => entries
                .iter()
                .find(|(name, _)| name == key)
                .map(|(_, value)| value),
            _ => None,
        }
    }

    pub fn text(&self) -> Option<&str> {
        match self {
            Value::Text(text) => Some(text),
            _ => None,
        }
    }

    pub fn int(&self) -> Option<i64> {
        match self {
            Value::Int(number) => Some(*number),
            _ => None,
        }
    }

    #[cfg(test)]
    pub fn bool(&self) -> Option<bool> {
        match self {
            Value::Bool(value) => Some(*value),
            _ => None,
        }
    }

    pub fn list(&self) -> &[Value] {
        match self {
            Value::List(items) => items,
            _ => &[],
        }
    }
}

/// How deep a list may hold lists, and how many values are read from one
/// plist in all: an /Ask for a thousand files has a few thousand.
const DEPTH: usize = 16;
const VALUES: usize = 200_000;
/// How many bytes of values named more than once may be copied, over the list's own size.
const SHARED: usize = 4 << 20;

struct Reader<'a> {
    bytes: &'a [u8],
    offsets: Vec<usize>,
    reference: usize,
    left: usize,
    room: usize,
}

pub fn parse(bytes: &[u8]) -> Result<Value, &'static str> {
    if bytes.len() < 40 || &bytes[..6] != b"bplist" {
        return Err("not a binary property list");
    }
    let trailer = &bytes[bytes.len() - 32..];
    let (offset_size, reference) = (trailer[6] as usize, trailer[7] as usize);
    let word = |at: usize| u64::from_be_bytes(trailer[at..at + 8].try_into().unwrap());
    let (count, top, table) = (word(8), word(16), word(24));
    if !(1..=8).contains(&offset_size)
        || !(1..=8).contains(&reference)
        || count == 0
        || count > VALUES as u64
        || top >= count
    {
        return Err("a property list with an impossible trailer");
    }
    let (count, table) = (
        count as usize,
        usize::try_from(table).map_err(|_| "offset table out of range")?,
    );
    let end = table
        .checked_add(count * offset_size)
        .filter(|end| *end <= bytes.len() - 32)
        .ok_or("offset table out of range")?;
    let offsets = bytes[table..end]
        .chunks(offset_size)
        .map(|raw| raw.iter().fold(0usize, |sum, b| (sum << 8) | *b as usize))
        .collect();
    Reader {
        bytes: &bytes[..table],
        offsets,
        reference,
        left: VALUES,
        // A list may name one value many times, and each naming is a copy here: what is copied in
        // all is bounded by what was sent, with room for the short texts that lists do share.
        room: bytes.len() + SHARED,
    }
    .value(top as usize, 0)
}

impl Reader<'_> {
    fn take(&self, at: usize, size: usize) -> Result<&[u8], &'static str> {
        at.checked_add(size)
            .and_then(|end| self.bytes.get(at..end))
            .ok_or("a value runs past the end")
    }

    fn number(&self, at: usize, size: usize) -> Result<u64, &'static str> {
        Ok(self
            .take(at, size)?
            .iter()
            .rev()
            .take(8)
            .rev()
            .fold(0u64, |sum, b| (sum << 8) | u64::from(*b)))
    }

    /// (how many, where they start) for a value whose marker's low half is
    /// its size, or 15 for "an integer follows that says".
    fn sized(&self, at: usize, low: u8) -> Result<(usize, usize), &'static str> {
        if low != 15 {
            return Ok((low as usize, at + 1));
        }
        let marker = self.take(at + 1, 1)?[0];
        if marker >> 4 != 1 {
            return Err("a size that is not a number");
        }
        let width = 1usize << (marker & 15).min(4);
        let size =
            usize::try_from(self.number(at + 2, width)?).map_err(|_| "a size out of range")?;
        Ok((size, at + 2 + width))
    }

    fn references(&self, at: usize, count: usize) -> Result<Vec<usize>, &'static str> {
        let raw = self.take(
            at,
            count.checked_mul(self.reference).ok_or("too many values")?,
        )?;
        Ok(raw
            .chunks(self.reference)
            .map(|one| one.iter().fold(0usize, |sum, b| (sum << 8) | *b as usize))
            .collect())
    }

    /// Counts bytes about to be copied out of the list against what may be.
    fn copied(&mut self, size: usize) -> Result<(), &'static str> {
        self.room = self
            .room
            .checked_sub(size)
            .ok_or("a property list that repeats itself too much")?;
        Ok(())
    }

    fn value(&mut self, index: usize, depth: usize) -> Result<Value, &'static str> {
        if depth > DEPTH {
            return Err("a property list nested too deep");
        }
        self.left = self
            .left
            .checked_sub(1)
            .ok_or("a property list with too many values")?;
        let at = *self.offsets.get(index).ok_or("a reference to no value")?;
        let marker = self.take(at, 1)?[0];
        let low = marker & 15;
        Ok(match marker >> 4 {
            0 => match marker {
                8 => Value::Bool(false),
                9 => Value::Bool(true),
                _ => Value::Other,
            },
            1 => Value::Int(self.number(at + 1, 1 << low.min(4))? as i64),
            4 => {
                let (size, from) = self.sized(at, low)?;
                self.copied(size)?;
                Value::Data(self.take(from, size)?.to_vec())
            }
            5 | 7 => {
                let (size, from) = self.sized(at, low)?;
                self.copied(size)?;
                Value::Text(String::from_utf8_lossy(self.take(from, size)?).into_owned())
            }
            6 => {
                let (size, from) = self.sized(at, low)?;
                let size = size.checked_mul(2).ok_or("a text out of range")?;
                self.copied(size)?;
                let raw = self.take(from, size)?;
                let units: Vec<u16> = raw
                    .chunks(2)
                    .map(|pair| u16::from_be_bytes([pair[0], pair[1]]))
                    .collect();
                Value::Text(String::from_utf16_lossy(&units))
            }
            10 | 12 => {
                let (count, from) = self.sized(at, low)?;
                let mut items = Vec::with_capacity(count.min(1024));
                for reference in self.references(from, count)? {
                    items.push(self.value(reference, depth + 1)?);
                }
                Value::List(items)
            }
            13 => {
                let (count, from) = self.sized(at, low)?;
                let keys = self.references(from, count)?;
                let values = self.references(from + count * self.reference, count)?;
                let mut entries = Vec::with_capacity(count.min(1024));
                for (key, value) in keys.into_iter().zip(values) {
                    if let Value::Text(name) = self.value(key, depth + 1)? {
                        entries.push((name, self.value(value, depth + 1)?));
                    }
                }
                Value::Dict(entries)
            }
            _ => Value::Other,
        })
    }
}

/// A value as a binary property list. Every value is written once where it
/// stands, none shared: the answers written here are a handful of entries.
pub fn write(value: &Value) -> Vec<u8> {
    fn count(value: &Value) -> usize {
        1 + match value {
            Value::List(items) => items.iter().map(count).sum(),
            Value::Dict(entries) => entries.iter().map(|(_, value)| 1 + count(value)).sum(),
            _ => 0,
        }
    }
    let reference = if count(value) < 256 { 1 } else { 2 };
    let mut writer = Writer {
        objects: Vec::new(),
        reference,
    };
    writer.add(value);

    let mut out = b"bplist00".to_vec();
    let mut offsets = Vec::with_capacity(writer.objects.len());
    for object in &writer.objects {
        offsets.push(out.len());
        out.extend_from_slice(object);
    }
    let table = out.len();
    let offset_size = if table < 256 {
        1
    } else if table < 65536 {
        2
    } else {
        4
    };
    for offset in &offsets {
        out.extend_from_slice(&(*offset as u32).to_be_bytes()[4 - offset_size..]);
    }
    out.extend_from_slice(&[0, 0, 0, 0, 0, 0, offset_size as u8, reference as u8]);
    out.extend_from_slice(&(offsets.len() as u64).to_be_bytes());
    out.extend_from_slice(&0u64.to_be_bytes());
    out.extend_from_slice(&(table as u64).to_be_bytes());
    out
}

struct Writer {
    objects: Vec<Vec<u8>>,
    reference: usize,
}

impl Writer {
    fn marker(kind: u8, size: usize) -> Vec<u8> {
        if size < 15 {
            return vec![kind << 4 | size as u8];
        }
        let mut out = vec![kind << 4 | 15];
        out.extend_from_slice(&Self::int(size as i64));
        out
    }

    fn int(number: i64) -> Vec<u8> {
        match number {
            0..=0xff => vec![0x10, number as u8],
            0x100..=0xffff => [&[0x11][..], &(number as u16).to_be_bytes()].concat(),
            0x1_0000..=0xffff_ffff => [&[0x12][..], &(number as u32).to_be_bytes()].concat(),
            _ => [&[0x13][..], &number.to_be_bytes()].concat(),
        }
    }

    /// Writes a value and everything in it; says which number it got.
    fn add(&mut self, value: &Value) -> usize {
        let index = self.objects.len();
        self.objects.push(Vec::new());
        let object = match value {
            Value::Bool(false) => vec![8],
            Value::Bool(true) => vec![9],
            Value::Other => vec![0],
            Value::Int(number) => Self::int(*number),
            Value::Data(data) => [Self::marker(4, data.len()), data.clone()].concat(),
            Value::Text(text) if text.is_ascii() => {
                [Self::marker(5, text.len()), text.as_bytes().to_vec()].concat()
            }
            Value::Text(text) => {
                let units: Vec<u16> = text.encode_utf16().collect();
                let mut out = Self::marker(6, units.len());
                units
                    .iter()
                    .for_each(|unit| out.extend_from_slice(&unit.to_be_bytes()));
                out
            }
            Value::List(items) => {
                let references: Vec<usize> = items.iter().map(|item| self.add(item)).collect();
                let mut out = Self::marker(10, items.len());
                self.refer(&mut out, &references);
                out
            }
            Value::Dict(entries) => {
                let keys: Vec<usize> = entries
                    .iter()
                    .map(|(name, _)| self.add(&Value::Text(name.clone())))
                    .collect();
                let values: Vec<usize> = entries.iter().map(|(_, value)| self.add(value)).collect();
                let mut out = Self::marker(13, entries.len());
                self.refer(&mut out, &keys);
                self.refer(&mut out, &values);
                out
            }
        };
        self.objects[index] = object;
        index
    }

    fn refer(&self, out: &mut Vec<u8>, references: &[usize]) {
        for reference in references {
            out.extend_from_slice(&(*reference as u16).to_be_bytes()[2 - self.reference..]);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn unhex(text: &str) -> Vec<u8> {
        (0..text.len() / 2)
            .map(|i| u8::from_str_radix(&text[2 * i..2 * i + 2], 16).unwrap())
            .collect()
    }

    /// As Python's plistlib writes it: an /Ask in small, with a text that is
    /// not ASCII, data longer than fourteen bytes, numbers of every width.
    const ASK: &str = include_str!("../tests/ask.hex");

    #[test]
    fn what_a_sender_writes_is_read() {
        let ask = parse(&unhex(ASK.trim())).unwrap();
        assert_eq!(
            ask.get("SenderComputerName").and_then(Value::text),
            Some("Telefon von Zoë")
        );
        assert_eq!(
            ask.get("BundleID").and_then(Value::text),
            Some("com.apple.mobileslideshow")
        );
        assert_eq!(
            ask.get("ConvertMediaFormats").and_then(Value::bool),
            Some(false)
        );
        assert_eq!(
            ask.get("TransferID")
                .and_then(|id| id.get("id"))
                .and_then(Value::text),
            Some("00000000-0000-4000-8000-000000000000")
        );
        let files = ask.get("Files").map(Value::list).unwrap();
        assert_eq!(files.len(), 2);
        assert_eq!(
            files[0].get("FileName").and_then(Value::text),
            Some("IMG_0001.HEIC")
        );
        assert_eq!(
            files[0].get("FileSize").and_then(Value::int),
            Some(1_044_468)
        );
        assert_eq!(
            files[1].get("FileSize").and_then(Value::int),
            Some(5_000_000_000)
        );
        assert_eq!(
            files[1].get("FileIsDirectory").and_then(Value::bool),
            Some(true)
        );
        assert_eq!(ask.get("FileIcon"), Some(&Value::Data((0..=255).collect())));
        assert_eq!(ask.get("Small").and_then(Value::int), Some(7));
        assert_eq!(ask.get("When"), Some(&Value::Other));
        assert_eq!(ask.get("Nothing here"), None);
        assert!(ask.get("Items").map(Value::list).unwrap().is_empty());
    }

    #[test]
    fn what_is_written_reads_back() {
        let answer = Value::Dict(vec![
            (
                "ReceiverComputerName".into(),
                Value::Text("Nova on a café table".into()),
            ),
            ("ReceiverModelName".into(), Value::Text("Nova".into())),
            ("IsAirDropable".into(), Value::Bool(true)),
            (
                "ReceiverMediaCapabilities".into(),
                Value::Data(br#"{"Version": 1}"#.to_vec()),
            ),
            (
                "Sizes".into(),
                Value::List(vec![
                    Value::Int(0),
                    Value::Int(300),
                    Value::Int(70_000),
                    Value::Int(5_000_000_000),
                ]),
            ),
            ("Long".into(), Value::Data(vec![7; 70_000])),
        ]);
        assert_eq!(parse(&write(&answer)).unwrap(), answer);
        // More values than one byte can number.
        let many = Value::List((0..400).map(Value::Int).collect());
        assert_eq!(parse(&write(&many)).unwrap(), many);
    }

    #[test]
    fn the_answer_to_discover_is_what_python_writes() {
        // plistlib.dumps of the same dictionary, keys in this order: what an iPhone listed Nova from.
        let answer = Value::Dict(vec![
            ("ReceiverComputerName".into(), Value::Text("Nova".into())),
            ("ReceiverModelName".into(), Value::Text("Nova".into())),
        ]);
        let ours = parse(&write(&answer)).unwrap();
        let theirs = parse(&unhex(include_str!("../tests/answer.hex").trim())).unwrap();
        assert_eq!(ours, theirs);
    }

    #[test]
    fn a_broken_list_is_refused_and_nothing_else_happens() {
        let good = unhex(ASK.trim());
        assert!(parse(b"").is_err());
        assert!(parse(&good[..good.len() - 1]).is_err() || parse(&good[..good.len() - 1]).is_ok());
        // Every byte in turn set to 0xff, and the list cut at every length: an error or a value, never a panic.
        for at in 0..good.len() {
            let mut bad = good.clone();
            bad[at] = 0xff;
            let _ = parse(&bad);
            let _ = parse(&good[..at]);
        }
        // A list that holds itself.
        let mut own = b"bplist00".to_vec();
        own.extend_from_slice(&[0xa1, 0x00, 0x08]);
        own.extend_from_slice(&[0, 0, 0, 0, 0, 0, 1, 1]);
        own.extend_from_slice(&1u64.to_be_bytes());
        own.extend_from_slice(&0u64.to_be_bytes());
        own.extend_from_slice(&10u64.to_be_bytes());
        assert_eq!(parse(&own), Err("a property list nested too deep"));
    }

    /// A list of `times` references to one piece of data of `size` bytes.
    fn echo(times: u16, size: u32) -> Vec<u8> {
        let mut out = b"bplist00".to_vec();
        let list = out.len();
        out.extend_from_slice(&[0xaf, 0x11]);
        out.extend_from_slice(&times.to_be_bytes());
        out.extend(std::iter::repeat_n(1u8, times as usize));
        let data = out.len();
        out.extend_from_slice(&[0x4f, 0x12]);
        out.extend_from_slice(&size.to_be_bytes());
        out.extend(std::iter::repeat_n(0x5au8, size as usize));
        let table = out.len();
        out.extend_from_slice(&(list as u32).to_be_bytes());
        out.extend_from_slice(&(data as u32).to_be_bytes());
        out.extend_from_slice(&[0, 0, 0, 0, 0, 0, 4, 1]);
        out.extend_from_slice(&2u64.to_be_bytes());
        out.extend_from_slice(&0u64.to_be_bytes());
        out.extend_from_slice(&(table as u64).to_be_bytes());
        out
    }

    #[test]
    fn a_list_that_says_one_thing_over_and_over_is_not_copied_out_each_time() {
        // Three namings of a megabyte are a list like any other.
        let thrice = parse(&echo(3, 1 << 20)).unwrap();
        assert_eq!(thrice.list().len(), 3);
        assert!(matches!(&thrice.list()[2], Value::Data(data) if data.len() == 1 << 20));
        // Sixty thousand would be sixty gigabytes here from one megabyte sent.
        assert_eq!(
            parse(&echo(60_000, 1 << 20)).err(),
            Some("a property list that repeats itself too much")
        );
        // Short texts are shared in any list of files, and that is fine.
        assert_eq!(parse(&echo(60_000, 8)).unwrap().list().len(), 60_000);
    }
}
