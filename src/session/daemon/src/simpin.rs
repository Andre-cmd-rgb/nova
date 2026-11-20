//! nova-sim-pin <SIM object path>: the SIM's PIN, read from the standard
//! input, sent to ModemManager over the system bus (Sim.SendPin). mobile-data
//! runs it rather than mmcli, which takes the PIN as an argument, where any
//! process could read it while it runs. An error is its D-Bus name and
//! message, as mmcli says them ("…IncorrectPassword: …"), which mobile-data
//! reads to say what went wrong.

use std::io::BufRead;
use std::time::Duration;

use nova_sd::{Bus, Error, Value};

const MODEM_MANAGER: &str = "org.freedesktop.ModemManager1";
const SIM: &str = "org.freedesktop.ModemManager1.Sim";
/// How long a SIM may take to check a PIN; ModemManager's own limit is
/// shorter, so its answer comes first.
const PATIENCE: Duration = Duration::from_secs(30);

/// Sends <pin> to the SIM at <sim>: none, or the words for what failed.
fn send(bus: &Bus, sim: &str, pin: &str) -> Result<(), String> {
    match bus.call_timeout(
        MODEM_MANAGER,
        sim,
        SIM,
        "SendPin",
        &[Value::str(pin)],
        Some(PATIENCE),
    ) {
        Ok(_) => Ok(()),
        Err(Error::Bus { name, message }) => Err(format!("{name}: {message}")),
        Err(e) => Err(e.to_string()),
    }
}

pub fn main() -> i32 {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let [sim] = args.as_slice() else {
        eprintln!("usage: nova-sim-pin <SIM object path>, the PIN on the standard input");
        return 2;
    };
    let mut line = String::new();
    if std::io::stdin().lock().read_line(&mut line).is_err() {
        eprintln!("nova-sim-pin: no PIN on the standard input");
        return 2;
    }
    let outcome = Bus::system()
        .map_err(|e| e.to_string())
        .and_then(|bus| send(&bus, sim, line.trim()));
    // The PIN no longer in this process's memory.
    // SAFETY: zeros are valid UTF-8.
    unsafe { line.as_bytes_mut().fill(0) };
    match outcome {
        Ok(()) => 0,
        Err(words) => {
            eprintln!("{words}");
            1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use nova_sd::testing::PrivateBus;
    use nova_sd::{Interface, Message};
    use std::sync::mpsc;
    use std::thread;
    use std::time::Instant;

    const PATH: &str = "/org/freedesktop/ModemManager1/SIM/0";

    /// ModemManager with one SIM whose PIN is 1234, on a bus of the test's.
    fn modem_manager(address: String, heard: mpsc::Sender<String>) {
        thread::spawn(move || {
            let bus = Bus::connect(&address).unwrap();
            let _slot = bus
                .export(
                    PATH,
                    vec![Interface::new(SIM).method("SendPin", "s", "")],
                    move |_: &Message, args: Vec<Value>| {
                        let pin = args[0].as_str().unwrap().to_owned();
                        heard.send(pin.clone()).unwrap();
                        if pin == "1234" {
                            Ok(vec![])
                        } else {
                            Err(Error::bus(
                                "org.freedesktop.ModemManager1.Error.MobileEquipment.IncorrectPassword",
                                "Incorrect password",
                            ))
                        }
                    },
                )
                .unwrap();
            assert!(bus.request_name(MODEM_MANAGER, 0).unwrap());
            loop {
                bus.wait(None).unwrap();
                bus.dispatch().unwrap();
            }
        });
    }

    #[test]
    fn the_pin_reaches_the_sim_and_a_wrong_one_says_so() {
        let Some(private) = PrivateBus::start() else {
            return;
        };
        let (heard_tx, heard) = mpsc::channel();
        modem_manager(private.address.clone(), heard_tx);
        let bus = Bus::connect(&private.address).unwrap();
        let until = Instant::now() + Duration::from_secs(5);
        while bus.name_owner(MODEM_MANAGER).unwrap().is_none() {
            assert!(Instant::now() < until, "the fake ModemManager never came");
            thread::sleep(Duration::from_millis(10));
        }
        assert_eq!(send(&bus, PATH, "1234"), Ok(()));
        assert_eq!(heard.recv().unwrap(), "1234");
        let said = send(&bus, PATH, "0000").unwrap_err();
        assert_eq!(
            said,
            "org.freedesktop.ModemManager1.Error.MobileEquipment.IncorrectPassword: Incorrect password"
        );
        assert!(said.contains("Incorrect"), "mobile-data reads the word");
        assert!(send(&bus, "/org/freedesktop/ModemManager1/SIM/9", "1234").is_err());
    }
}
