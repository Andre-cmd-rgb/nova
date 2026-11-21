//! The three X11 requests the settings pass needs, spoken by hand over the
//! settings' socket: the connection's setup, an atom's number, and who owns a
//! selection. No Xlib: this runs once, before any app is let in.

use std::io::{self, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::{Duration, Instant};

const INTERN_ATOM: u8 = 16;
const GET_SELECTION_OWNER: u8 = 23;

fn odd(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.to_string())
}

/// The setup request of a client that sends its numbers low byte first and
/// brings no authorization (the X server takes the session's own user).
pub fn setup_request() -> [u8; 12] {
    [b'l', 0, 11, 0, 0, 0, 0, 0, 0, 0, 0, 0]
}

/// InternAtom for a name: its number, made if nobody has asked before.
pub fn intern_atom_request(name: &str) -> Vec<u8> {
    let padded = name.len().div_ceil(4) * 4;
    let mut request = vec![INTERN_ATOM, 0];
    request.extend_from_slice(&((2 + padded / 4) as u16).to_le_bytes());
    request.extend_from_slice(&(name.len() as u16).to_le_bytes());
    request.extend_from_slice(&[0, 0]);
    request.extend_from_slice(name.as_bytes());
    request.resize(8 + padded, 0);
    request
}

pub fn selection_owner_request(atom: u32) -> [u8; 8] {
    let atom = atom.to_le_bytes();
    [GET_SELECTION_OWNER, 0, 2, 0, atom[0], atom[1], atom[2], atom[3]]
}

/// The number a reply carries in its bytes 8 to 12 (an atom, or a window):
/// the next reply on the connection, past any event the server sent meanwhile.
fn reply_number(stream: &mut UnixStream) -> io::Result<u32> {
    loop {
        let mut packet = [0u8; 32];
        stream.read_exact(&mut packet)?;
        match packet[0] {
            0 => return Err(odd("the X server refused a request")),
            1 => {
                // Neither reply has more than its 32 bytes.
                if packet[4..8] != [0, 0, 0, 0] {
                    return Err(odd("a longer reply than asked for"));
                }
                return Ok(u32::from_le_bytes([packet[8], packet[9], packet[10], packet[11]]));
            }
            _ => continue,
        }
    }
}

/// Returns once the selection has an owner, or says why it could not tell:
/// no X server behind the socket, or none by the deadline.
pub fn wait_for_owner(socket: &Path, selection: &str, deadline: Instant) -> io::Result<()> {
    let mut stream = UnixStream::connect(socket)?;
    let patience = deadline.saturating_duration_since(Instant::now()).max(Duration::from_millis(100));
    stream.set_read_timeout(Some(patience))?;
    stream.write_all(&setup_request())?;
    let mut head = [0u8; 8];
    stream.read_exact(&mut head)?;
    let mut rest = vec![0u8; usize::from(u16::from_le_bytes([head[6], head[7]])) * 4];
    stream.read_exact(&mut rest)?;
    if head[0] != 1 {
        return Err(odd("the X server refused the connection"));
    }
    stream.write_all(&intern_atom_request(selection))?;
    let atom = reply_number(&mut stream)?;
    loop {
        stream.write_all(&selection_owner_request(atom))?;
        if reply_number(&mut stream)? != 0 {
            return Ok(());
        }
        if Instant::now() >= deadline {
            return Err(io::Error::new(io::ErrorKind::TimedOut, "nobody took it in time"));
        }
        std::thread::sleep(Duration::from_millis(5));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::net::UnixListener;

    #[test]
    fn the_requests_are_as_the_protocol_has_them() {
        assert_eq!(setup_request().len(), 12);
        // 13 letters: three bytes of padding, a request of six words.
        let request = intern_atom_request("_XSETTINGS_S0");
        assert_eq!(request.len(), 24);
        assert_eq!(&request[..8], &[16, 0, 6, 0, 13, 0, 0, 0]);
        assert_eq!(&request[8..21], b"_XSETTINGS_S0");
        assert_eq!(&request[21..], &[0, 0, 0]);
        assert_eq!(intern_atom_request("WM_S").len(), 12);
        assert_eq!(selection_owner_request(0x1_02), [23, 0, 2, 0, 2, 1, 0, 0]);
    }

    /// An X server of the test's own: the setup, the atom, then "no owner"
    /// twice (with an event in between) before a window owns the selection.
    #[test]
    fn it_waits_until_the_selection_has_an_owner() {
        let dir = std::env::temp_dir().join(format!("nova-xwayland-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("x");
        let _ = std::fs::remove_file(&path);
        let listener = UnixListener::bind(&path).unwrap();
        let server = std::thread::spawn(move || {
            let (mut client, _) = listener.accept().unwrap();
            let mut setup = [0u8; 12];
            client.read_exact(&mut setup).unwrap();
            assert_eq!(setup, setup_request());
            // Success, with two more words after the eight bytes.
            client.write_all(&[1, 0, 11, 0, 0, 0, 2, 0, 9, 9, 9, 9, 9, 9, 9, 9]).unwrap();
            let mut intern = [0u8; 24];
            client.read_exact(&mut intern).unwrap();
            let mut reply = [0u8; 32];
            reply[0] = 1;
            reply[8..12].copy_from_slice(&77u32.to_le_bytes());
            client.write_all(&reply).unwrap();
            let mut asked = 0;
            for owner in [0u32, 0, 0x40_0001] {
                let mut request = [0u8; 8];
                client.read_exact(&mut request).unwrap();
                assert_eq!(request, selection_owner_request(77));
                asked += 1;
                // An event the client did not ask for comes first.
                let mut event = [0u8; 32];
                event[0] = 34;
                client.write_all(&event).unwrap();
                let mut reply = [0u8; 32];
                reply[0] = 1;
                reply[8..12].copy_from_slice(&owner.to_le_bytes());
                client.write_all(&reply).unwrap();
            }
            asked
        });
        wait_for_owner(&path, "_XSETTINGS_S0", Instant::now() + Duration::from_secs(5)).unwrap();
        assert_eq!(server.join().unwrap(), 3);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn no_x_server_behind_the_socket_is_said_not_waited_for() {
        let missing = std::env::temp_dir().join("nova-xwayland-test-no-such-socket");
        let started = Instant::now();
        assert!(wait_for_owner(&missing, "_XSETTINGS_S0", Instant::now() + Duration::from_secs(5)).is_err());
        assert!(started.elapsed() < Duration::from_secs(1));
    }
}
