//! Hyprland's two sockets, read directly: its events (.socket2.sock), one
//! line each, and its requests (.socket.sock), as hyprctl makes them.

use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, RawFd};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::Duration;

/// Hyprland's events, as they come.
pub struct Events {
    stream: UnixStream,
    partial: Vec<u8>,
}

impl Events {
    pub fn connect(hypr: &Path) -> io::Result<Events> {
        let stream = UnixStream::connect(hypr.join(".socket2.sock"))?;
        stream.set_nonblocking(true)?;
        Ok(Events {
            stream,
            partial: Vec::new(),
        })
    }

    pub fn fd(&self) -> RawFd {
        self.stream.as_raw_fd()
    }

    /// The whole lines that have come since the last read; none once
    /// Hyprland has closed the socket (it ended).
    pub fn lines(&mut self) -> io::Result<Option<Vec<String>>> {
        let mut buffer = [0u8; 8192];
        let mut ended = false;
        loop {
            match self.stream.read(&mut buffer) {
                Ok(0) => {
                    ended = true;
                    break;
                }
                Ok(n) => self.partial.extend_from_slice(&buffer[..n]),
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                Err(e) => return Err(e),
            }
        }
        let mut lines = Vec::new();
        while let Some(end) = self.partial.iter().position(|&b| b == b'\n') {
            let line: Vec<u8> = self.partial.drain(..=end).collect();
            lines.push(String::from_utf8_lossy(&line[..end]).into_owned());
        }
        if ended && lines.is_empty() {
            return Ok(None);
        }
        Ok(Some(lines))
    }
}

/// Asks Hyprland, as `hyprctl` would (`j/clients` for `hyprctl -j clients`),
/// and gives its answer; two seconds at most.
pub fn request(hypr: &Path, what: &str) -> io::Result<String> {
    let mut stream = UnixStream::connect(hypr.join(".socket.sock"))?;
    stream.set_read_timeout(Some(Duration::from_secs(2)))?;
    stream.set_write_timeout(Some(Duration::from_secs(2)))?;
    stream.write_all(what.as_bytes())?;
    let mut answer = String::new();
    stream.read_to_string(&mut answer)?;
    Ok(answer)
}

/// An event's name and its data: "closewindow>>abc" is ("closewindow", "abc").
pub fn split(line: &str) -> (&str, &str) {
    line.split_once(">>").unwrap_or((line, ""))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::net::UnixListener;

    #[test]
    fn events_come_a_whole_line_at_a_time_until_hyprland_ends() {
        let dir = nova_sd::testing::scratch("hypr");
        let listener = UnixListener::bind(dir.join(".socket2.sock")).unwrap();
        let mut events = Events::connect(&dir).unwrap();
        let (mut hyprland, _) = listener.accept().unwrap();
        hyprland.write_all(b"openwindow>>abc,1,foot,a ti").unwrap();
        std::thread::sleep(Duration::from_millis(20));
        assert_eq!(events.lines().unwrap(), Some(vec![]));
        hyprland.write_all(b"tle\nclosewindow>>abc\n").unwrap();
        std::thread::sleep(Duration::from_millis(20));
        assert_eq!(
            events.lines().unwrap(),
            Some(vec![
                "openwindow>>abc,1,foot,a title".into(),
                "closewindow>>abc".into()
            ])
        );
        drop(hyprland);
        std::thread::sleep(Duration::from_millis(20));
        assert_eq!(events.lines().unwrap(), None);
        assert_eq!(split("closewindow>>abc"), ("closewindow", "abc"));
        assert_eq!(split("configreloaded>>"), ("configreloaded", ""));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
