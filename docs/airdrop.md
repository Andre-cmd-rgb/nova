# AirDrop

Nova receives what an iPhone sends with AirDrop: photos, videos, files, links. It is real AirDrop, spoken over Apple's own radio link, so the iPhone needs nothing installed and no network in common with the computer.

- **Receiving only, so far.** Sending from Nova to an iPhone is not there yet.
- **While AirDrop is on, the Wi-Fi is off the network** ([why](#why-the-wi-fi-goes)). It ends by itself and the Wi-Fi reconnects.
- **It needs a Wi-Fi card that can do two things** ([which](#which-cards)). It was built and measured on the Intel AX210.

## Using it

1. **Switch it on:** the menu → Toggle → AirDrop, or `nova airdrop on`. A card under the bar says it is on.
2. **On the iPhone:** Share → AirDrop. The computer appears under its own name within a few seconds. Tap it.
3. **Say yes:** the card names the iPhone and what it offers. Accept, or Decline.
4. **It comes in:** the card shows how much has arrived. When it is in, a notification says where it is; a click opens it.

What arrives goes to your downloads folder. Nothing there is ever replaced: a second `IMG_0412.HEIC` becomes `IMG_0412 2.HEIC`.

**It ends by itself:** a moment after a transfer, whichever way it went, or after two minutes in which nobody offered anything. Stop on the card, the menu's row again, or `nova airdrop off` ends it sooner. The Wi-Fi is connected again four or five seconds later.

If the computer does not appear on the iPhone, set the iPhone's own AirDrop to Everyone for 10 Minutes (Settings → General → AirDrop) and open the share sheet again: that is how it was tested.

### The command

| | |
|---|---|
| `nova airdrop` | how it is, in a line |
| `nova airdrop on`, `off`, `toggle` | switch it |
| `nova airdrop accept`, `decline` | answer what is being offered |
| `nova airdrop available` | whether this computer's card can do it, and why not |
| `nova airdrop active` | succeeds while it is on (for scripts) |
| `nova airdrop watch` | each change as a line of JSON (what the shell reads) |

`nova airdrop off` waits until the Wi-Fi has been handed back and says how that went.

## Why the Wi-Fi goes

**A Wi-Fi card is on one channel at a time.** Your network is on its channel. iPhones talk AirDrop on three channels of their own (6, 44 and 149), hopping between them and their own network sixteen times a second, by a timetable they announce. A computer's card cannot follow that hopping and stay on its network, so for as long as AirDrop is on, Nova lends the card to AirDrop whole: it leaves the network and sits on channel 6.

- **A wired connection is not touched.**
- **Bluetooth is not touched.**
- **Sleep ends it:** AirDrop stops before the computer sleeps, and the Wi-Fi is the network's again when it wakes.

## Which cards

`nova airdrop available` answers for the computer it runs on. The card must:

- start an ad-hoc cell (`IBSS` in `iw phy`'s interface modes): that is what makes its hardware acknowledge the frames an iPhone sends, and an iPhone repeats every frame seven times to a receiver that does not;
- give a monitor interface, to hear and send the frames themselves;
- be allowed to send on channel 6 where the computer is.

Cards with Linux's own Wi-Fi stack (mac80211) mostly can. **Only the Intel AX210 has been tried.** On a card that cannot hold a second interface beside the Wi-Fi's own, Nova turns the Wi-Fi's interface itself into the cell and back; that path has no hardware it was tried on yet.

## What it lets in

**While AirDrop is on, anybody in radio range can see the computer's name in their share sheet and offer it something.** That is what Everyone means on an iPhone too. Showing only to your contacts takes an identity Apple issues to its own devices, which a PC cannot have.

- **Nothing is taken unasked.** Every offer waits for Accept, for 55 seconds, and is declined after that.
- **One offer at a time.** A second sender is declined while one is being asked or received.
- **The name shown** is the computer's (`hostnamectl --pretty`, else its host name).
- **What arrives is files and folders, in the downloads folder, and nothing else.** An archive's names that point outside it, its links and its device files are dropped; it may not be much larger than the sender said.
- **The receiver is not root.** It runs as you, with one capability (to open its socket on the radio), which it gives up once it has the socket.
- **AirDrop is all a phone can reach.** Its network lives in a namespace of its own, with one interface and one listening port: nothing else running on the computer (a printer queue, a login server, file sharing) is on that link.
- **It is on only while you want it.** Nothing starts it at login.

## How it is built

For those working on it. The code is in `src/airdrop/`, and the shell's card in `src/shell/plugins/airdrop/`.

| Part | Is |
|---|---|
| `nova-airdropd` (`daemon/`, Rust) | the receiver: an AWDL node on the air, and AirDrop's HTTPS on top |
| `nova-airdrop` (`daemon/src/bin/`, Rust) | `nova airdrop`: switches it, answers it, watches it |
| `nova-airdrop-radio` (`bin/`, bash) | lends the Wi-Fi card (`up`) and takes it back (`down`), as root |
| `nova-airdrop@.service` | runs `up`, then the daemon as the user who asked, then `down` however it ended |
| `nova-airdrop-apply` and `org.nova.airdrop` | the root half of on and off, through pkexec, with no password for the person at the computer |

**The radio.** `up` takes the Wi-Fi interface from NetworkManager and adds two interfaces to the card under one made-up address: `nova-cell`, an ad-hoc cell on channel 6 with AWDL's BSSID (`00:25:00:ff:94:73`), HT20, a beacon every ten seconds (an iPhone does not list a node whose cell beacons ten times a second); and `nova-mon`, a monitor interface. The cell is there for the card's hardware to acknowledge frames sent to that address. The frames themselves are heard and sent on the monitor.

**The node** (`node.rs`, `wire.rs`). AWDL nodes announce themselves in action frames: a short one every 110 time units and a long one every second, carrying the node's clock, the channel it is on in each of sixteen slots, and whom it follows as master. The daemon announces a timetable of channel 6 in every slot. An iPhone that hears it answers pings, lists the service, and sends its data in the slots where its own timetable says 6: one slot in sixteen while idle, five once it is talking to somebody. The node keeps each peer's timetable and clock from its announcements and sends to a peer only while that peer is on the channel, holding frames until then.

**IP.** AWDL carries IPv6 between link-local addresses made from the nodes' addresses. The daemon makes a TAP interface, `awdl0`, in a network namespace of its own, and passes packets between it and the air: the kernel does TCP. The namespace is the daemon's alone (it takes a user namespace to make one without root), so nothing of the system listens on that link and nothing of the system reconfigures the interface. The daemon answers the kernel's neighbour questions itself, and mDNS for `_airdrop._tcp` (`packet.rs`).

**AirDrop** (`receiver.rs`, `http.rs`, `tls.rs`, `plist.rs`, `unpack.rs`). HTTPS on port 8771 with a certificate the daemon makes itself, on first use, in `~/.local/state/nova/airdrop`. A sender posts to `/Discover` and is told the computer's name; to `/Ask`, a binary property list of what it offers, and waits for 200 or anything else; then to `/Upload` on the same connection, one archive: cpio, packed either with gzip or, as iPhones do, in pieces that are each a zlib stream of their own. It is unpacked as it arrives into a hidden folder inside the downloads folder and moved into place when it is whole; a transfer that stops leaves nothing. The answer goes the moment the last byte is in, while the phone is still on the channel to hear it.

**Nothing but the system's libraries.** The daemon has no dependencies in cargo. TLS is the system's OpenSSL, loaded when the daemon starts; unpacking is the system's zlib.

**Talking to it** (`control.rs`). A socket in the user's runtime folder, `nova/airdrop.sock`. A client says one line (`watch`, `status`, `accept`, `decline`, `stop`); a watcher gets the state as a line of JSON at each change. The file's own comment has the states and their fields.

### Putting the Wi-Fi back

This is the part that must not fail, and `nova-airdrop-radio` is written round it:

- **The card's own address comes from the card** (`phy80211/macaddress`), never from the interface. NetworkManager puts a random address on a card while it scans, and takes the address a card has when it is handed back for the card's own: an early test script read the address during a scan, restored that, and the router refused the laptop until a restart.
- **What there is to undo is noted in `/run/nova-airdrop` before anything is changed**, and undoing takes the note first: it can be asked for twice and happens once.
- **Each step of the undoing is tried whatever became of the one before.**
- **Only `nova-cell` and `nova-mon` are ever deleted**, by name.
- **`down` is the unit's `ExecStopPost`**, which systemd runs however the daemon ended and when it never started. A daemon that hangs stops telling systemd it is alive and is ended (`WatchdogSec`).
- **`down` waits for NetworkManager to be connected again** where it was before, asks it outright after eight seconds, and says how long it took, or plainly that the Wi-Fi is not back. `nova airdrop off` prints that line.

### Trying it without a phone

- `cargo test -p nova-airdropd`: the frame formats against frames an iPhone answered, the unpackers, the HTTP reader, TLS against `openssl s_client`, the node against a made-up phone that keeps a timetable, the control socket.
- `tests/unit/airdrop/radio.bats`: `nova-airdrop-radio` against stand-ins for `iw`, `ip` and `nmcli`, with a card that shows another address than its own.
- `tests/qml/airdrop-test.qml`: the card against a stand-in for `nova airdrop`.

### What is not there

- **Sending.** It takes Bluetooth announcements to wake the iPhone's AirDrop, and AirDrop's client side.
- **The 5 GHz channels.** An iPhone spends most of its slots on channel 44; Intel cards may not send there. Channel 6 is where every card may.
- **A picture of your own in the iPhone's list.** The iPhone draws the picture from the kind of computer the receiver says it is; a photo is shown only for a contact with an Apple identity.
