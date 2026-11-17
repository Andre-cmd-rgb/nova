//! What wakes an iPhone's AirDrop: a Bluetooth announcement of a computer
//! that wants to send.
//!
//! An iPhone keeps AirDrop off its Wi-Fi until it hears, over Bluetooth, a
//! nearby device announcing that it is about to send something: Apple's
//! manufacturer data (company 0x004c), message 0x05, the one the doorbell
//! hears from an iPhone whose share sheet shows AirDrop. Then for a while it
//! is an AWDL node, and its AirDrop is listed on that link like this
//! computer's is. The message carries the sender's own number and short
//! hashes of the sender's phone number and addresses, for an iPhone that
//! takes AirDrop from its contacts only to check against its contacts: this
//! computer has no Apple ID and gives none (zeros). An iPhone set to
//! Everyone for 10 Minutes wakes for any sender.
//!
//! The advertisement goes out from the controller's own address. The kernel
//! gives an advertisement a random one only when it cannot be connected to,
//! or when Bluetooth privacy is on (`Privacy=device` in bluetoothd's
//! main.conf, for the whole controller); this one counts as connectable
//! whenever the controller is, as bluetoothd has it, and no flag of the
//! management interface asks otherwise (net/bluetooth/hci_sync.c). So while
//! it sends, whoever listens nearby hears this computer's Bluetooth address,
//! the one it has for good, unless privacy is on: that is the user's to
//! choose, and is not changed from here.
//!
//! It is given to the controller through the kernel's Bluetooth management
//! (mgmt.rs), as an advertisement of the computer's own, not through BlueZ's
//! LEAdvertisingManager1. That could carry it as well, but it calls back into
//! an object the advertiser serves on the system bus, and Nova's Rust has no
//! D-Bus to serve one with; the management socket is what the doorbell
//! already speaks. It costs the capability to bind that socket (CAP_NET_ADMIN),
//! which is why this runs in a process of its own (announcer.rs), and
//! bluetoothd does not know of the advertisement: it takes the highest
//! number free, where bluetoothd hands out the lowest, and is said again
//! every few seconds, which brings it back should anything have taken it
//! away. The kernel ends it by itself a little after that: a daemon that
//! died leaves nothing announcing.

use std::os::fd::{AsRawFd, RawFd};

use crate::mgmt::{self, Mgmt};

const READ_ADV_FEATURES: u16 = 0x003d;
const ADD_ADVERTISING: u16 = 0x003e;
const REMOVE_ADVERTISING: u16 = 0x003f;

/// Why it cannot announce, as the send window and `nova airdrop send` say it.
pub const OFF: &str = "Bluetooth is off. Turn it on to send to an iPhone.";
pub const NO_LE: &str =
    "Bluetooth Low Energy is off. Turn it on in Settings → Bluetooth to send to an iPhone.";

/// How long the controller announces after it was last told to: a little longer than between
/// two tellings (announcer.rs).
const LASTS: u16 = 20;

/// What the controller is given to announce: the flags an iPhone gives its own, and Apple's
/// manufacturer data with message 0x05 in it, 18 bytes: eight of nothing, the message's version
/// (1), the four short hashes (none, here), and one of nothing.
pub fn announcement() -> Vec<u8> {
    let mut message = vec![0u8; 8];
    message.push(0x01);
    message.extend_from_slice(&[0u8; 8]);
    message.push(0);
    let mut data = vec![0x02, 0x01, 0x1a];
    data.push(3 + 2 + message.len() as u8);
    data.extend_from_slice(&[0xff, 0x4c, 0x00, 0x05, message.len() as u8]);
    data.extend_from_slice(&message);
    data
}

/// The command that puts it in place: instance, no flags of the kernel's own (the advertisement
/// carries its flags itself, and is connectable as the controller is), no duration of its own, how
/// long it lasts, the data, no scan response.
fn adding(instance: u8) -> Vec<u8> {
    let data = announcement();
    let mut params = vec![instance];
    params.extend_from_slice(&0u32.to_le_bytes());
    params.extend_from_slice(&0u16.to_le_bytes());
    params.extend_from_slice(&LASTS.to_le_bytes());
    params.push(data.len() as u8);
    params.push(0);
    params.extend_from_slice(&data);
    params
}

/// The number for this advertisement: the highest the controller has that is not in use, from
/// the answer to READ_ADV_FEATURES (flags, two lengths, how many it can have, how many it has, and
/// their numbers).
fn free_instance(features: &[u8]) -> Option<u8> {
    let (&most, &count) = (features.get(6)?, features.get(7)?);
    let taken = features.get(8..8 + usize::from(count)).unwrap_or(&[]);
    (1..=most).rev().find(|instance| !taken.contains(instance))
}

/// The Bluetooth half of sending, in the announcer's process.
pub struct Wake {
    mgmt: Mgmt,
    /// (controller, the advertisement's number) while it is announcing.
    on: Option<(u16, u8)>,
}

impl Wake {
    /// The management socket, bound while the capability is there.
    pub fn open() -> Result<Wake, String> {
        Ok(Wake {
            mgmt: Mgmt::open().map_err(|error| format!("Bluetooth: {error}"))?,
            on: None,
        })
    }

    /// The descriptor the management socket's events come on.
    pub fn events(&self) -> RawFd {
        self.mgmt.fd.as_raw_fd()
    }

    /// Reads and lets go of the events that came, none of which this needs: a queue nobody reads
    /// fills, and then the answers are dropped too. How many there were.
    pub fn drain(&mut self) -> usize {
        let mut drained = 0;
        while self.mgmt.read().is_some() {
            drained += 1;
        }
        drained
    }

    /// Announces, or says again what it announces; why not, in a sentence for the user, when it
    /// cannot.
    pub fn announce(&mut self) -> Result<(), String> {
        // What the kernel told meanwhile is nothing this needs.
        self.mgmt.early.clear();
        let Some((index, settings)) = self.mgmt.controller() else {
            self.on = None;
            return Err("This computer has no Bluetooth, which sending to an iPhone needs.".into());
        };
        if settings & mgmt::POWERED == 0 {
            self.on = None;
            return Err(OFF.into());
        }
        // Switched off by the user, the kernel refuses the announcement as "rejected": said so.
        if settings & mgmt::LE == 0 {
            self.on = None;
            return Err(NO_LE.into());
        }
        let instance = match self.on {
            Some((on, instance)) if on == index => instance,
            _ => {
                let (status, features) = self.mgmt.ask(READ_ADV_FEATURES, index, &[]);
                if status != 0 {
                    return Err(format!(
                        "Bluetooth would not announce this computer ({}).",
                        mgmt::status_words(status)
                    ));
                }
                free_instance(&features)
                    .ok_or("Bluetooth has no room to announce this computer.")?
            }
        };
        let (status, _) = self.mgmt.ask(ADD_ADVERTISING, index, &adding(instance));
        self.mgmt.early.clear();
        if status != 0 {
            self.on = None;
            return Err(format!(
                "Bluetooth would not announce this computer ({}).",
                mgmt::status_words(status)
            ));
        }
        self.on = Some((index, instance));
        Ok(())
    }

    /// Stops announcing.
    pub fn quiet(&mut self) {
        if let Some((index, instance)) = self.on.take() {
            self.mgmt.ask(REMOVE_ADVERTISING, index, &[instance]);
            self.mgmt.early.clear();
        }
    }
}

impl Drop for Wake {
    fn drop(&mut self) {
        self.quiet();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_announcement_is_apples_airdrop_message_with_no_apple_id_in_it() {
        let data = announcement();
        assert_eq!(data.len(), 27, "within an advertisement's 31 bytes");
        assert_eq!(&data[..3], &[0x02, 0x01, 0x1a]);
        // One structure of manufacturer data, Apple's, message 0x05 of 18 bytes.
        assert_eq!(&data[3..9], &[23, 0xff, 0x4c, 0x00, 0x05, 18]);
        assert_eq!(usize::from(data[3]), data.len() - 4);
        let message = &data[9..];
        assert_eq!(message.len(), 18);
        assert!(message[..8].iter().all(|b| *b == 0));
        assert_eq!(message[8], 1);
        assert!(message[9..].iter().all(|b| *b == 0));
    }

    #[test]
    fn the_command_is_laid_out_as_the_kernel_reads_it() {
        let params = adding(5);
        assert_eq!(&params[..11], &[5, 0, 0, 0, 0, 0, 0, LASTS as u8, 0, 27, 0]);
        assert_eq!(&params[11..], &announcement()[..]);
    }

    #[test]
    fn it_takes_the_highest_number_nobody_has() {
        // flags, data and scan lengths, five it can have, two it has: 1 and 5.
        let features = [0, 0, 0, 0, 31, 31, 5, 2, 1, 5];
        assert_eq!(free_instance(&features), Some(4));
        assert_eq!(free_instance(&[0, 0, 0, 0, 31, 31, 1, 0]), Some(1));
        assert_eq!(free_instance(&[0, 0, 0, 0, 31, 31, 1, 1, 1]), None);
        assert_eq!(free_instance(&[0, 0, 0, 0, 31, 31, 0, 0]), None);
        assert_eq!(free_instance(&[0, 0]), None);
    }
}
