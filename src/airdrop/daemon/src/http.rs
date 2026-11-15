//! HTTP/1.1, as much of it as AirDrop speaks: a sender posts to three paths
//! on one connection, with bodies in chunks or of a stated length, and is
//! answered with a status and a small body.
//!
//! Bodies are read as they come and never gathered here: the third path's is
//! the upload itself.

use std::io::{self, Read, Write};
use std::time::{Duration, Instant};

/// A request's first line and headers.
#[derive(Debug)]
pub struct Head {
    pub method: String,
    pub path: String,
    headers: Vec<(String, String)>,
}

impl Head {
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(key, _)| key.eq_ignore_ascii_case(name))
            .map(|(_, value)| value.as_str())
    }

    /// The sender waits to be told to send the body.
    pub fn expects_continue(&self) -> bool {
        self.header("expect")
            .is_some_and(|value| value.eq_ignore_ascii_case("100-continue"))
    }

    /// The sender will make no further request on this connection.
    pub fn closes(&self) -> bool {
        self.header("connection")
            .is_some_and(|value| value.eq_ignore_ascii_case("close"))
    }
}

fn bad(what: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, what)
}

/// A connection's bytes, read ahead of where the reading is.
pub struct Connection<S> {
    stream: S,
    buffer: Vec<u8>,
    at: usize,
    /// When what is being read must be in: a sender that sends a byte at a time is within every
    /// timeout of the socket's, and is not waited for without end.
    by: Option<Instant>,
}

const HEAD_LIMIT: usize = 16 << 10;
/// How long a request's head has to arrive, from its first byte.
const HEAD_WITHIN: Duration = Duration::from_secs(15);

impl<S: Read + Write> Connection<S> {
    pub fn new(stream: S) -> Connection<S> {
        Connection {
            stream,
            buffer: Vec::with_capacity(64 << 10),
            at: 0,
            by: None,
        }
    }

    /// What is read from here on must be in within this long (None: however long it takes).
    pub fn within(&mut self, time: Option<Duration>) {
        self.by = time.map(|time| Instant::now() + time);
    }

    pub fn stream(&mut self) -> &mut S {
        &mut self.stream
    }

    /// Reads more from the sender; false when it has closed the connection.
    fn fill(&mut self) -> io::Result<bool> {
        if self.by.is_some_and(|by| Instant::now() >= by) {
            return Err(io::ErrorKind::TimedOut.into());
        }
        if self.at == self.buffer.len() {
            self.buffer.clear();
            self.at = 0;
        } else if self.at > 32 << 10 {
            self.buffer.drain(..self.at);
            self.at = 0;
        }
        let have = self.buffer.len();
        self.buffer.resize(have + (64 << 10), 0);
        let got = self.stream.read(&mut self.buffer[have..]);
        self.buffer.truncate(have + *got.as_ref().unwrap_or(&0));
        Ok(got? > 0)
    }

    /// The bytes up to the next line end, which is taken too.
    fn line(&mut self, limit: usize) -> io::Result<Vec<u8>> {
        loop {
            if let Some(end) = self.buffer[self.at..]
                .windows(2)
                .position(|pair| pair == b"\r\n")
            {
                let line = self.buffer[self.at..self.at + end].to_vec();
                self.at += end + 2;
                return Ok(line);
            }
            if self.buffer.len() - self.at > limit {
                return Err(bad("a line of the request is too long"));
            }
            if !self.fill()? {
                return Err(io::ErrorKind::UnexpectedEof.into());
            }
        }
    }

    /// The next request's head; None if the sender closed the connection instead of sending one.
    pub fn head(&mut self) -> io::Result<Option<Head>> {
        while self.at == self.buffer.len() {
            if !self.fill()? {
                return Ok(None);
            }
        }
        self.within(Some(HEAD_WITHIN));
        let head = self.rest_of_head();
        self.within(None);
        head
    }

    fn rest_of_head(&mut self) -> io::Result<Option<Head>> {
        let first = String::from_utf8_lossy(&self.line(HEAD_LIMIT)?).into_owned();
        let mut words = first.split(' ');
        let (Some(method), Some(path), Some(version)) = (words.next(), words.next(), words.next())
        else {
            return Err(bad("not an HTTP request"));
        };
        if !version.starts_with("HTTP/1.") {
            return Err(bad("not HTTP/1.1"));
        }
        let mut head = Head {
            method: method.to_owned(),
            path: path.to_owned(),
            headers: Vec::new(),
        };
        let mut size = first.len();
        loop {
            let line = self.line(HEAD_LIMIT)?;
            if line.is_empty() {
                return Ok(Some(head));
            }
            size += line.len();
            if size > HEAD_LIMIT || head.headers.len() >= 64 {
                return Err(bad("the request's headers are too long"));
            }
            let line = String::from_utf8_lossy(&line);
            if let Some((name, value)) = line.split_once(':') {
                head.headers
                    .push((name.trim().to_owned(), value.trim().to_owned()));
            }
        }
    }

    /// The body that follows a head.
    pub fn body(&mut self, head: &Head) -> io::Result<Body<'_, S>> {
        let state = if head
            .header("transfer-encoding")
            .is_some_and(|value| value.to_ascii_lowercase().contains("chunked"))
        {
            State::ChunkSize
        } else {
            match head.header("content-length") {
                None => State::Done,
                Some(length) => State::Sized(
                    length
                        .parse()
                        .map_err(|_| bad("a content length that is not a number"))?,
                ),
            }
        };
        Ok(Body {
            connection: self,
            state,
        })
    }

    /// Reads and forgets what the sender still sends, until it stops or closes: a connection closed
    /// with something unread is reset, and a reset can overtake the answer.
    pub fn drain(&mut self) {
        let mut budget = 4 << 20;
        self.buffer.clear();
        self.at = 0;
        while budget > 0 {
            match self.fill() {
                Ok(true) => budget -= self.buffer.len().min(budget),
                _ => break,
            }
            self.buffer.clear();
        }
    }

    /// Tells a sender that asked to go on with its body.
    pub fn go_on(&mut self) -> io::Result<()> {
        self.stream.write_all(b"HTTP/1.1 100 Continue\r\n\r\n")
    }

    /// An answer, in one write: one piece to the sender where it fits in one.
    pub fn respond(&mut self, status: u16, body: &[u8], close: bool) -> io::Result<()> {
        let reason = match status {
            200 => "OK",
            400 => "Bad Request",
            403 => "Forbidden",
            405 => "Method Not Allowed",
            _ => "Internal Server Error",
        };
        let mut answer = format!(
            "HTTP/1.1 {status} {reason}\r\nContent-Type: application/octet-stream\r\nContent-Length: {}\r\nConnection: {}\r\n\r\n",
            body.len(),
            if close { "close" } else { "keep-alive" }
        )
        .into_bytes();
        answer.extend_from_slice(body);
        self.stream.write_all(&answer)?;
        self.stream.flush()
    }
}

/// A request's body, read as it arrives.
pub struct Body<'a, S> {
    connection: &'a mut Connection<S>,
    state: State,
}

enum State {
    Sized(u64),
    ChunkSize,
    Chunk(u64),
    ChunkEnd,
    Trailers,
    Done,
}

impl<S: Read + Write> Body<'_, S> {
    /// The whole body, if it is no longer than `limit`.
    pub fn all(&mut self, limit: usize) -> io::Result<Vec<u8>> {
        let mut whole = Vec::new();
        let mut piece = [0u8; 16 << 10];
        loop {
            match self.read(&mut piece)? {
                0 => return Ok(whole),
                size if whole.len() + size > limit => {
                    return Err(bad("the request's body is too long"))
                }
                size => whole.extend_from_slice(&piece[..size]),
            }
        }
    }
}

impl<S: Read + Write> Read for Body<'_, S> {
    fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
        let c = &mut *self.connection;
        loop {
            match self.state {
                State::Done => return Ok(0),
                State::Sized(0) => self.state = State::Done,
                State::Chunk(0) => self.state = State::ChunkEnd,
                State::Sized(left) | State::Chunk(left) => {
                    if c.at == c.buffer.len() && !c.fill()? {
                        return Err(io::ErrorKind::UnexpectedEof.into());
                    }
                    let take = (c.buffer.len() - c.at)
                        .min(out.len())
                        .min(usize::try_from(left).unwrap_or(usize::MAX));
                    out[..take].copy_from_slice(&c.buffer[c.at..c.at + take]);
                    c.at += take;
                    self.state = match self.state {
                        State::Sized(_) => State::Sized(left - take as u64),
                        _ => State::Chunk(left - take as u64),
                    };
                    if take > 0 {
                        return Ok(take);
                    }
                }
                State::ChunkSize => {
                    // A size in hex, and after a semicolon things nobody uses.
                    let line = c.line(256)?;
                    let digits = line.split(|byte| *byte == b';').next().unwrap_or(&[]);
                    let size = std::str::from_utf8(digits)
                        .ok()
                        .and_then(|text| u64::from_str_radix(text.trim(), 16).ok());
                    self.state = match size.ok_or_else(|| bad("a chunk with no size"))? {
                        0 => State::Trailers,
                        size => State::Chunk(size),
                    };
                }
                State::ChunkEnd => {
                    if !c.line(2)?.is_empty() {
                        return Err(bad("a chunk longer than its size"));
                    }
                    self.state = State::ChunkSize;
                }
                State::Trailers => {
                    if c.line(HEAD_LIMIT)?.is_empty() {
                        self.state = State::Done;
                    }
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A sender that has said everything already, handed over a few bytes at a time.
    struct Sender {
        said: Vec<u8>,
        at: usize,
        step: usize,
        heard: Vec<u8>,
    }

    impl Read for Sender {
        fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
            let take = self.step.min(out.len()).min(self.said.len() - self.at);
            out[..take].copy_from_slice(&self.said[self.at..self.at + take]);
            self.at += take;
            Ok(take)
        }
    }

    impl Write for Sender {
        fn write(&mut self, data: &[u8]) -> io::Result<usize> {
            self.heard.extend_from_slice(data);
            Ok(data.len())
        }
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    fn connection(said: &[u8], step: usize) -> Connection<Sender> {
        Connection::new(Sender {
            said: said.to_vec(),
            at: 0,
            step,
            heard: Vec::new(),
        })
    }

    /// What an iPhone's three requests look like, with made-up contents.
    fn requests() -> Vec<u8> {
        let mut said = b"POST /Ask HTTP/1.1\r\nUser-Agent: AirDrop/1.0\r\nConnection: keep-alive\r\nTransfer-Encoding: chunked\r\n\r\n".to_vec();
        said.extend_from_slice(
            b"5\r\nhello\r\n1a;name=value\r\nabcdefghijklmnopqrstuvwxyz\r\n0\r\n\r\n",
        );
        said.extend_from_slice(b"POST /Upload HTTP/1.1\r\nContent-Type: application/x-dvzip\r\nExpect: 100-continue\r\ncontent-length: 10\r\n\r\n0123456789");
        said.extend_from_slice(b"GET / HTTP/1.1\r\nConnection: close\r\n\r\n");
        said
    }

    #[test]
    fn three_requests_on_one_connection_are_read_however_they_arrive() {
        for step in [1, 2, 7, 4096] {
            let mut c = connection(&requests(), step);
            let ask = c.head().unwrap().unwrap();
            assert_eq!(
                (
                    ask.method.as_str(),
                    ask.path.as_str(),
                    ask.header("USER-AGENT")
                ),
                ("POST", "/Ask", Some("AirDrop/1.0"))
            );
            assert!(!ask.closes() && !ask.expects_continue());
            assert_eq!(
                c.body(&ask).unwrap().all(100).unwrap(),
                b"helloabcdefghijklmnopqrstuvwxyz"
            );

            let upload = c.head().unwrap().unwrap();
            assert!(upload.expects_continue());
            c.go_on().unwrap();
            let mut body = c.body(&upload).unwrap();
            let mut piece = [0u8; 4];
            let mut whole = Vec::new();
            loop {
                match body.read(&mut piece).unwrap() {
                    0 => break,
                    size => whole.extend_from_slice(&piece[..size]),
                }
            }
            assert_eq!(whole, b"0123456789");
            c.respond(200, b"", true).unwrap();

            let last = c.head().unwrap().unwrap();
            assert!(last.closes());
            assert_eq!(c.body(&last).unwrap().all(10).unwrap(), b"");
            assert!(c.head().unwrap().is_none(), "the sender is done");
            assert_eq!(
                c.stream().heard,
                b"HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            );
        }
    }

    #[test]
    fn what_is_broken_or_too_long_is_an_error() {
        let whole = |said: &[u8], limit: usize| {
            let mut c = connection(said, 3);
            let head = c.head()?.unwrap();
            c.body(&head)?.all(limit)
        };
        assert!(
            whole(
                b"POST /Ask HTTP/1.1\r\nContent-Length: 50\r\n\r\nshort",
                100
            )
            .is_err(),
            "cut off"
        );
        assert!(
            whole(b"POST /Ask HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello", 4).is_err(),
            "over the limit"
        );
        assert!(whole(
            b"POST /Ask HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\nhello\r\n0\r\n\r\n",
            100
        )
        .is_err());
        assert!(whole(
            b"POST /Ask HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nhello\r\n0\r\n\r\n",
            100
        )
        .is_err());
        assert!(whole(b"POST /Ask HTTP/1.1\r\nContent-Length: many\r\n\r\n", 100).is_err());
        assert!(connection(b"\x16\x03\x01 not HTTP at all\r\n\r\n", 5)
            .head()
            .is_err());
        assert!(connection(b"POST /Ask SPDY/3\r\n\r\n", 5).head().is_err());
        let mut long = b"POST /Ask HTTP/1.1\r\n".to_vec();
        long.extend_from_slice(&[b'a'; 20 << 10]);
        assert!(connection(&long, 4096).head().is_err());
        let many: Vec<u8> = [
            &b"POST /Ask HTTP/1.1\r\n"[..],
            &b"A: b\r\n".repeat(100)[..],
            b"\r\n",
        ]
        .concat();
        assert!(connection(&many, 4096).head().is_err());
    }
}
