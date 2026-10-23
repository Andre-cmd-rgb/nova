//! Intel's overclocking mailbox, MSR 0x150, which is how a voltage offset
//! reaches the CPU. A command goes in with the busy bit set, and the CPU
//! clears the bit once its answer is in the register, with a status byte in
//! bits 39:32. The same protocol intel-undervolt uses, and the one measured on
//! a P1 Gen 4i in docs/hardware/thinkpad-p1-gen4i.md (fact 16).

use std::fmt;
use std::fs::{File, OpenOptions};
use std::io;
use std::os::unix::fs::FileExt;
use std::thread::sleep;
use std::time::{Duration, Instant};

const OC_MAILBOX: u32 = 0x150;
/// MSR_FLEX_RATIO: bit 20 is the firmware's Overclocking Lock, which makes
/// the mailbox take an offset and discard it.
const FLEX_RATIO: u32 = 0x194;
const OC_LOCK: u64 = 1 << 20;
const BUSY: u64 = 1 << 63;
const READ: u64 = 0x10;
const WRITE: u64 = 0x11;
/// Bits 31:21 of a plane's settings: the offset, signed, in 1/1.024 mV.
const OFFSET_MASK: u32 = 0xFFE0_0000;

/// The planes moved, always together: the cores and the cache (ring) share
/// one voltage on these CPUs, so an offset on only one of them does nothing.
pub const PLANES: [(u64, &str); 2] = [(0, "core"), (2, "cache")];

pub trait Msr {
    fn read(&mut self, register: u32) -> io::Result<u64>;
    fn write(&mut self, register: u32, value: u64) -> io::Result<()>;
}

/// The registers of CPU 0. The mailbox and the lock are package-wide.
pub struct CpuMsr(File);

impl CpuMsr {
    pub fn open() -> io::Result<CpuMsr> {
        OpenOptions::new()
            .read(true)
            .write(true)
            .open("/dev/cpu/0/msr")
            .map(CpuMsr)
    }
}

impl Msr for CpuMsr {
    fn read(&mut self, register: u32) -> io::Result<u64> {
        let mut bytes = [0u8; 8];
        self.0.read_exact_at(&mut bytes, register.into())?;
        Ok(u64::from_le_bytes(bytes))
    }

    fn write(&mut self, register: u32, value: u64) -> io::Result<()> {
        self.0.write_all_at(&value.to_le_bytes(), register.into())
    }
}

#[derive(Debug)]
pub enum Error {
    Io(io::Error),
    Busy,
    Status(u64),
    Discarded {
        plane: &'static str,
        wanted: f64,
        got: f64,
    },
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            Error::Io(e) => write!(f, "{e}"),
            Error::Busy => write!(f, "the mailbox stayed busy"),
            Error::Status(s) => write!(f, "the mailbox answered status {s:#x}"),
            Error::Discarded { plane, wanted, got } => write!(
                f,
                "the {plane} plane reads back {got:.1} mV after {wanted:.1} mV was written"
            ),
        }
    }
}

impl From<io::Error> for Error {
    fn from(e: io::Error) -> Error {
        Error::Io(e)
    }
}

/// An offset in whole millivolts as the mailbox's field: 1/1.024 mV steps,
/// so -70 mV is -72 steps, which is -70.3 mV.
pub fn encode(millivolts: i32) -> u32 {
    let steps = (f64::from(millivolts) * 1.024).round() as i32;
    ((steps as u32) & 0x7FF) << 21
}

pub fn decode(settings: u32) -> f64 {
    let steps = ((settings >> 21) & 0x7FF) as i32;
    let steps = if steps & 0x400 != 0 {
        steps - 0x800
    } else {
        steps
    };
    f64::from(steps) / 1.024
}

fn wait_ready(msr: &mut dyn Msr) -> Result<u64, Error> {
    let deadline = Instant::now() + Duration::from_millis(100);
    loop {
        let value = msr.read(OC_MAILBOX)?;
        if value & BUSY == 0 {
            return Ok(value);
        }
        if Instant::now() >= deadline {
            return Err(Error::Busy);
        }
        sleep(Duration::from_millis(1));
    }
}

fn command(msr: &mut dyn Msr, plane: u64, op: u64, data: u32) -> Result<u32, Error> {
    wait_ready(msr)?;
    msr.write(OC_MAILBOX, BUSY | plane << 40 | op << 32 | u64::from(data))?;
    let answer = wait_ready(msr)?;
    match (answer >> 32) & 0xFF {
        0 => Ok(answer as u32),
        status => Err(Error::Status(status)),
    }
}

pub fn locked(msr: &mut dyn Msr) -> io::Result<bool> {
    Ok(msr.read(FLEX_RATIO)? & OC_LOCK != 0)
}

/// The offset a plane has now, in millivolts.
pub fn offset(msr: &mut dyn Msr, plane: u64) -> Result<f64, Error> {
    Ok(decode(command(msr, plane, READ, 0)?))
}

/// Gives every plane the offset, keeping the rest of each plane's settings,
/// and reads each back: a locked mailbox takes a write without complaint and
/// discards it, which only the read-back shows.
pub fn set(msr: &mut dyn Msr, millivolts: i32) -> Result<(), Error> {
    for (plane, name) in PLANES {
        let current = command(msr, plane, READ, 0)?;
        let wanted = (current & !OFFSET_MASK) | encode(millivolts);
        command(msr, plane, WRITE, wanted)?;
        let got = command(msr, plane, READ, 0)?;
        if got & OFFSET_MASK != wanted & OFFSET_MASK {
            return Err(Error::Discarded {
                plane: name,
                wanted: decode(wanted),
                got: decode(got),
            });
        }
    }
    Ok(())
}

/// A mailbox in memory, answering the way the CPU does.
#[cfg(test)]
pub mod fake {
    use super::*;

    pub struct Fake {
        /// Each plane's settings, with bits besides the offset set, so a
        /// write that loses them shows.
        pub planes: [u32; 5],
        pub lock: bool,
        /// Takes writes and keeps nothing, as a locked mailbox does.
        pub discard: bool,
        pub writes: usize,
        answer: u64,
    }

    impl Fake {
        pub fn new() -> Fake {
            Fake {
                planes: [0x0000_0123; 5],
                lock: false,
                discard: false,
                writes: 0,
                answer: 0,
            }
        }
    }

    impl Msr for Fake {
        fn read(&mut self, register: u32) -> io::Result<u64> {
            match register {
                OC_MAILBOX => Ok(self.answer),
                FLEX_RATIO => Ok(0x10000 | if self.lock { OC_LOCK } else { 0 }),
                _ => Err(io::Error::from_raw_os_error(5)),
            }
        }

        fn write(&mut self, register: u32, value: u64) -> io::Result<()> {
            assert_eq!(register, OC_MAILBOX);
            assert_ne!(value & BUSY, 0, "a command without the busy bit");
            let plane = ((value >> 40) & 0xF) as usize;
            self.answer = match (value >> 32) & 0xFF {
                READ => u64::from(self.planes[plane]),
                WRITE => {
                    self.writes += 1;
                    if !self.discard {
                        self.planes[plane] = value as u32;
                    }
                    0
                }
                _ => 1 << 32,
            };
            Ok(())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::fake::Fake;
    use super::*;

    #[test]
    fn offsets_round_trip_in_the_mailboxs_steps() {
        assert_eq!(encode(0), 0);
        // -70 mV is -72 steps of 1/1.024 mV.
        assert_eq!(encode(-70), ((-72i32 as u32) & 0x7FF) << 21);
        assert!((decode(encode(-70)) - -70.3125).abs() < 1e-9);
        assert!((decode(encode(-5)) - -4.8828125).abs() < 1e-9);
        assert!((decode(encode(-150)) - -150.390625).abs() < 1e-9);
    }

    #[test]
    fn set_moves_core_and_cache_and_keeps_their_other_settings() {
        let mut cpu = Fake::new();
        set(&mut cpu, -70).unwrap();
        for plane in [0, 2] {
            assert_eq!(cpu.planes[plane], 0x0000_0123 | encode(-70));
            assert!((offset(&mut cpu, plane as u64).unwrap() - -70.3125).abs() < 1e-9);
        }
        // The GPU, system agent and analog planes are left alone.
        assert_eq!(cpu.planes[1], 0x0000_0123);
        set(&mut cpu, 0).unwrap();
        assert_eq!(cpu.planes[0], 0x0000_0123);
    }

    #[test]
    fn a_write_the_mailbox_discards_is_an_error() {
        let mut cpu = Fake::new();
        cpu.discard = true;
        match set(&mut cpu, -70) {
            Err(Error::Discarded { plane: "core", .. }) => {}
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn the_lock_is_bit_20_of_flex_ratio() {
        let mut cpu = Fake::new();
        assert!(!locked(&mut cpu).unwrap());
        cpu.lock = true;
        assert!(locked(&mut cpu).unwrap());
    }

    #[test]
    fn a_mailbox_that_stays_busy_times_out() {
        struct Stuck;
        impl Msr for Stuck {
            fn read(&mut self, _: u32) -> io::Result<u64> {
                Ok(BUSY)
            }
            fn write(&mut self, _: u32, _: u64) -> io::Result<()> {
                Ok(())
            }
        }
        assert!(matches!(offset(&mut Stuck, 0), Err(Error::Busy)));
    }
}
