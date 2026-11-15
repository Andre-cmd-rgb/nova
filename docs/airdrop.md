# AirDrop

Nova receives what an iPhone sends with AirDrop: photos, videos, files, links. It is real AirDrop, spoken over Apple's own radio link, so the iPhone needs nothing installed and no network in common with the computer.

- **Receiving only, so far.** Sending from Nova to an iPhone is not there yet.
- **While AirDrop is on, the Wi-Fi is off the network** ([why](#why-the-wi-fi-goes)). It ends by itself and the Wi-Fi reconnects.
- **It needs a Wi-Fi card that can do two things** ([which](#which-cards)). It was built and measured on the Intel AX210, with an iPhone 15 Pro.

## Using it

1. **Switch it on:** the menu → Toggle → AirDrop, or `nova airdrop on`. The bar's Wi-Fi icon becomes AirDrop's while it is on.
2. **On the iPhone:** Share → AirDrop. The computer appears under its own name within a few seconds. Tap it.
3. **Say yes:** a notification names the iPhone and what it offers, as on a Mac. Accept, or Decline. Unanswered, it is declined after 55 seconds, before the iPhone gives up.
4. **It comes in:** a transfer that takes more than a moment shows its bar in a notification. When it is in, a notification says where it is, with the photo's picture; a click opens it.

What arrives goes to your downloads folder. Nothing there is ever replaced: a second `IMG_0412.HEIC` becomes `IMG_0412 2.HEIC`.

**It ends by itself:** a moment after a transfer, whichever way it went, or after two minutes in which nobody offered anything. The menu's row again, or `nova airdrop off`, ends it sooner. The Wi-Fi is connected again four or five seconds later.

The iPhone's own AirDrop setting (Contacts Only, Everyone) is about what the iPhone receives. It sends to the computer either way.

### Switched on by your iPhone

Settings → AirDrop → **Turn on for my iPhone**, or `nova airdrop bell on`. From then on there is nothing to switch: tap AirDrop in your iPhone's share sheet and the computer is in its list a few seconds later; close the sheet and AirDrop goes off, and the Wi-Fi comes back.

- **It learns your iPhone once.** Switched on, it asks you to open Share → AirDrop on the iPhone beside the computer, within a minute. After that only that iPhone switches AirDrop on; somebody else's share sheet nearby does not. Forget, on the same page, unlearns it.
- **Only while the computer is unlocked.** Locked, nothing happens, and an AirDrop it switched on goes off.
- **It never wakes the computer.** Before the computer sleeps the doorbell stops, which takes its pattern out of the Bluetooth controller; it starts again once the computer is awake.
- **Once a sheet.** An AirDrop that ends while the sheet is still open (switched off from the menu, two minutes with nothing sent) is not switched on again until the sheet has closed.
- **It does not end after a transfer**, as one switched on by hand does: a second photo can follow from the same sheet. The sheet's closing ends it, or two minutes with nothing sent.

**How it knows.** An iPhone announces itself over Bluetooth while its share sheet shows AirDrop, about five times a second, and stops when the sheet closes: it does not announce at Share alone, only once AirDrop is tapped, and goes on while the sheet stays open. Nova gives the Bluetooth controller a pattern of your iPhone's announcement, and the controller compares what it hears with it by itself: the computer is told only when it matches, and is not woken otherwise.

**What it costs.** Measured on the ThinkPad P1's Intel AX210: in the 12 seconds before the sheet was opened, the computer was told nothing at all; with the sheet open, once a second; "gone" came 2.2 s after the sheet closed. What the controller's own listening draws has not been measured. A controller that cannot compare patterns by itself is not used: the kernel would then have to look at every Bluetooth advertisement nearby, awake, and the page says so.

**What it keeps.** Four two-byte numbers from your iPhone's announcement, the ones that are the same from one share sheet to the next (the iPhone shuffles their order and changes the rest each time), in `~/.local/state/nova/airdrop/phones`, readable by you alone. Nothing of any other phone is kept or logged.

Bluetooth must be on for it to hear anything; the page says when it cannot listen, and why.

**Once, the Bluetooth chip reset itself.** On the P1 the Wi-Fi and Bluetooth share one chip, and once in testing, while AirDrop was busy on channel 6, its Bluetooth threw a hardware error and the kernel reset it. It was back a tenth of a second later, and AirDrop went on as if nothing had happened, but a device connected over Bluetooth (headphones) would have dropped for that moment.

**Measured** on the ThinkPad P1 Gen 4i with an iPhone 15 Pro: the computer is in the iPhone's list 1.2 s after AirDrop is switched on, a 1.0 MB photo arrives in 2.3 s, and the Wi-Fi is connected again 4 s after AirDrop ends. The speed is the iPhone's timetable: it is on the computer's channel in five of its sixteen slots while it sends, and in one while it only looks.

### The command

| | |
|---|---|
| `nova airdrop` | how it is, in a line |
| `nova airdrop on`, `off`, `toggle` | switch it |
| `nova airdrop on --stay` | on, and not ending after a transfer |
| `nova airdrop accept`, `decline` | answer what is being offered |
| `nova airdrop available` | whether this computer's card can do it, and why not |
| `nova airdrop active` | succeeds while it is on (for scripts) |
| `nova airdrop watch` | each change as a line of JSON (what the shell reads) |
| `nova airdrop bell on`, `off` | the doorbell: your iPhone switches AirDrop on and off |
| `nova airdrop bell learn`, `forget` | learn an iPhone in the next minute; know none |
| `nova airdrop bell`, `bell watch` | how the doorbell is, in a line or as JSON |

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
- **It is on only while you want it.** Nothing starts it at login. With the doorbell on, your iPhone's share sheet does, and nobody else's.

## How it is built

For those working on it. The code is in `src/airdrop/`, and the shell's part (its notifications, the doorbell's rule) in `src/shell/plugins/airdrop/`.

| Part | Is |
|---|---|
| `nova-airdropd` (`daemon/`, Rust) | the receiver: an AWDL node on the air, and AirDrop's HTTPS on top |
| `nova-airdrop` (`daemon/src/bin/`, Rust) | `nova airdrop`: switches it, answers it, watches it |
| `nova-airdrop-radio` (`bin/`, bash) | lends the Wi-Fi card (`up`) and takes it back (`down`), as root |
| `nova-airdrop@.service` | runs `up`, then the daemon as the user who asked, then `down` however it ended |
| `nova-airdrop-apply` and `org.nova.airdrop` | the root half of on and off, through pkexec, with no password for the person at the computer |
| `nova-airdrop-bell` (`daemon/src/bin/`, Rust) | the doorbell: the Bluetooth controller listening for the user's iPhone |
| `nova-airdrop-bell@.service` | runs it as the user, from each login to its end, once `nova airdrop bell on` has enabled it; stops it before the computer sleeps |
| `nova-airdrop-bell-wake@.service` | starts it again once the computer is awake |

**The radio.** `up` takes the Wi-Fi interface from NetworkManager and adds two interfaces to the card under one made-up address: `nova-cell`, an ad-hoc cell on channel 6 with AWDL's BSSID (`00:25:00:ff:94:73`), HT20, a beacon every ten seconds (an iPhone does not list a node whose cell beacons ten times a second); and `nova-mon`, a monitor interface. The cell is there for the card's hardware to acknowledge frames sent to that address. The frames themselves are heard and sent on the monitor.

**The node** (`node.rs`, `wire.rs`). AWDL nodes announce themselves in action frames: a short one every 110 time units and a long one every second, carrying the node's clock, the channel it is on in each of sixteen slots, and whom it follows as master. The daemon announces a timetable of channel 6 in every slot. An iPhone that hears it answers pings, lists the service, and sends its data in the slots where its own timetable says 6: one slot in sixteen while idle, five once it is talking to somebody. The node keeps each peer's timetable and clock from its announcements and sends to a peer only while that peer is on the channel, holding frames until then.

**IP.** AWDL carries IPv6 between link-local addresses made from the nodes' addresses. The daemon makes a TAP interface, `awdl0`, in a network namespace of its own, and passes packets between it and the air: the kernel does TCP. The namespace is the daemon's alone (it takes a user namespace to make one without root), so nothing of the system listens on that link and nothing of the system reconfigures the interface. The daemon answers the kernel's neighbour questions itself, and mDNS for `_airdrop._tcp` (`packet.rs`).

**AirDrop** (`receiver.rs`, `http.rs`, `tls.rs`, `plist.rs`, `unpack.rs`). HTTPS on port 8771 with a certificate the daemon makes itself, on first use, in `~/.local/state/nova/airdrop`. A sender posts to `/Discover` and is told the computer's name; to `/Ask`, a binary property list of what it offers, and waits for 200 or anything else; then to `/Upload` on the same connection, one archive: cpio, packed either with gzip or, as iPhones do, in pieces that are each a zlib stream of their own. It is unpacked as it arrives into a hidden folder inside the downloads folder and moved into place when it is whole; a transfer that stops leaves nothing. The answer goes the moment the last byte is in, while the phone is still on the channel to hear it.

**Nothing but the system's libraries.** The daemon has no dependencies in cargo. TLS is the system's OpenSSL, loaded when the daemon starts; unpacking is the system's zlib.

**Talking to it** (`control.rs`). A socket in the user's runtime folder, `nova/airdrop.sock`. A client says one line (`watch`, `status`, `accept`, `decline`, `stop`); a watcher gets the state as a line of JSON at each change. The file's own comment has the states and their fields.

**The notifications** (`src/shell/plugins/airdrop/`). The shell watches the daemon and sends Nova's notifications itself, with busctl: each word of what a sender calls itself and its files is one value there, never an option, and goes into the body escaped. The offer carries its Decline and Accept as the `nova-buttons` hint, commands the notifications run as they are; a transfer its bar as the standard `value` hint, in place under one id. A photo that came in gets a 256-pixel copy for its picture, made with `vipsthumbnail` with untrusted loaders blocked (`VIPS_BLOCK_UNTRUSTED`), since Qt reads no HEIC; one that cannot be made leaves the AirDrop glyph. The iPhone also sends a small picture with its offer, as JPEG 2000; it is not shown, since it would be decoding a stranger's file before the user said yes.

**The doorbell** (`nova-airdrop-bell`). It talks to the kernel's Bluetooth management socket, the one `bluetoothd` uses, and not to BlueZ: BlueZ's own interface for advertisement monitors is experimental, and switching it on would switch on other experimental parts too. Binding that socket takes `CAP_NET_ADMIN`, which the unit gives it; the kernel decides at binding what a socket may do, so it gives up every capability right after. It puts one advertisement monitor in place per iPhone it knows: four patterns, one for each of the iPhone's numbers in the first place of the announcement, any of which matches (the first place always holds one of them; an iPhone with fewer numbers is looked for in every place). Thresholds: found at once above -85 dBm, gone after 3 s below -95 dBm or unheard, told once a second meanwhile. While learning, a fifth monitor matches any iPhone's announcement (`4c 00 05` in Apple's data), and an iPhone louder than -65 dBm is the one learned. While something searches for Bluetooth devices (Settings' Bluetooth page), the kernel reports what a monitor matches as any device found, and those reports count too; an iPhone unheard for six seconds is gone, whatever the kernel said. A controller that goes off or away for a moment (the AX210 resets itself now and then) does not make the iPhone gone: for five seconds after, the kernel's "gone" waits for those six seconds. It notices Bluetooth switched off and on, the controller coming and going, and its monitors taken away, and puts them back; the monitors it put in place are noted in the runtime folder, so that a doorbell that died is tidied after. Its socket is `nova/airdrop-bell.sock` in the user's runtime folder: `watch`, `status`, `learn`, `forget`. The shell's AirDrop plugin does the rest (`Model.doorbell` in `AirDropModel.js`).

### Putting the Wi-Fi back

This is the part that must not fail, and `nova-airdrop-radio` is written round it:

- **The card's own address comes from the card** (`phy80211/macaddress`), never from the interface. NetworkManager puts a random address on a card while it scans, and takes the address a card has when it is handed back for the card's own: an early test script read the address during a scan, restored that, and the router refused the laptop until a restart.
- **What there is to undo is noted in `/run/nova-airdrop` before anything is changed**, and undoing takes the note first: it can be asked for twice and happens once.
- **Each step of the undoing is tried whatever became of the one before.**
- **Only `nova-cell` and `nova-mon` are ever deleted**, by name.
- **`down` is the unit's `ExecStopPost`**, which systemd runs however the daemon ended and when it never started. A daemon that hangs stops telling systemd it is alive and is ended (`WatchdogSec`).
- **`down` waits for NetworkManager to be connected again** where it was before, asks it outright after eight seconds, and says how long it took, or plainly that the Wi-Fi is not back. `nova airdrop off` prints that line.

### Trying it without a phone

- `cargo test -p nova-airdropd`: the frame formats against frames an iPhone answered, the unpackers, the HTTP reader, TLS against `openssl s_client`, the node against a made-up phone that keeps a timetable, the control socket, the doorbell's reading of an announcement and its patterns.
- `tests/unit/airdrop/radio.bats`: `nova-airdrop-radio` against stand-ins for `iw`, `ip` and `nmcli`, with a card that shows another address than its own.
- `tests/qml/airdrop-test.qml`: the shell's part against stand-ins for `nova airdrop`, the notifications (busctl) and `vipsthumbnail`, the doorbell's rule among it.
- `tests/unit/airdrop/apply.bats`: the doorbell enabled for whoever asked, and nobody else.

### What is not there

- **Sending.** It takes Bluetooth announcements to wake the iPhone's AirDrop, and AirDrop's client side.
- **The 5 GHz channels.** An iPhone spends most of its slots on channel 44; Intel cards may not send there. Channel 6 is where every card may.
- **A picture of your own in the iPhone's list.** The iPhone draws the picture from the kind of computer the receiver says it is; a photo is shown only for a contact with an Apple identity.
