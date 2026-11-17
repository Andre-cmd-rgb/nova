# AirDrop

Nova receives what an iPhone sends with AirDrop: photos, videos, files, links. And it sends files to an iPhone. It is real AirDrop, spoken over Apple's own radio link, so the iPhone needs nothing installed and no network in common with the computer.

- **Sending takes an iPhone set to Everyone for 10 Minutes** ([why](#sending)). Sending is new: it was tried against Nova's own receiver, not yet with an iPhone.
- **While AirDrop is on, the Wi-Fi is off the network** ([why](#why-the-wi-fi-goes)). It ends by itself and the Wi-Fi reconnects.
- **It needs a Wi-Fi card that can do two things** ([which](#which-cards)). It was built and measured on the Intel AX210, with an iPhone 15 Pro.

## Using it

1. **Switch it on:** the menu → Toggle → AirDrop, or `nova airdrop on`. The bar's Wi-Fi icon becomes AirDrop's while it is on.
2. **On the iPhone:** Share → AirDrop. The computer appears under its own name within a few seconds. Tap it.
3. **Say yes:** a notification names the iPhone and what it offers, as on a Mac. Accept, or Decline. Unanswered, it is declined after 55 seconds, before the iPhone gives up.
4. **It comes in:** a transfer that takes more than a moment shows its bar in a notification. When it is in, a notification says where it is, with the photo's picture; a click opens it.

What arrives goes to your downloads folder. Nothing there is ever replaced: a second `IMG_0412.HEIC` becomes `IMG_0412 2.HEIC`.

**It ends by itself:** a moment after a transfer, whichever way it went, or after two minutes in which nobody offered anything. The menu's row again, or `nova airdrop off`, ends it sooner, and a send that is going on with it. The Wi-Fi is connected again four or five seconds later.

The iPhone's own AirDrop setting (Contacts Only, Everyone) is about what the iPhone receives. It sends to the computer either way.

### Switched on by your iPhone

Settings → AirDrop → **Turn on for my iPhone**, or `nova airdrop bell on`. From then on there is nothing to switch: tap AirDrop in your iPhone's share sheet and the computer is in its list a few seconds later; close the sheet and AirDrop goes off, and the Wi-Fi comes back. Not if you switched it on yourself meanwhile, or a send is going on: then it is theirs, and ends as they do.

- **It learns your iPhone once.** Switched on, it asks you to open Share → AirDrop on the iPhone beside the computer, within a minute. After that only that iPhone switches AirDrop on; somebody else's share sheet nearby does not. Forget, on the same page, unlearns it.
- **Only while the computer is unlocked.** Locked, nothing happens, and an AirDrop it switched on goes off.
- **It never wakes the computer.** Before the computer sleeps the doorbell stops, which takes its pattern out of the Bluetooth controller; it starts again once the computer is awake.
- **It rests while the screen is locked.** AirDrop does not come on for your iPhone then anyway, so the pattern comes out of the controller at the lock, and the radio does not look for it at all; it goes back in at the unlock.
- **Once a sheet.** An AirDrop that ends while the sheet is still open (switched off from the menu, two minutes with nothing sent) is not switched on again until the sheet has closed.
- **It does not end after a transfer**, as one switched on by hand does: a second photo can follow from the same sheet. The sheet's closing ends it, or two minutes with nothing sent.

**How it knows.** An iPhone announces itself over Bluetooth while its share sheet shows AirDrop, about five times a second, and stops when the sheet closes: it does not announce at Share alone, only once AirDrop is tapped, and goes on while the sheet stays open. Nova gives the Bluetooth controller a pattern of your iPhone's announcement, and the controller compares what it hears with it by itself: the computer is told only when it matches, and is not woken otherwise.

**What it costs.** Measured on the ThinkPad P1's Intel AX210: in the 12 seconds before the sheet was opened, the computer was told nothing at all; with the sheet open, once a second; "gone" came 2.2 s after the sheet closed. What the controller's own listening draws has not been measured. To listen, the controller scans, and the kernel's scan for it is 30 ms of every 60, half the radio's time; the doorbell sets it to 30 ms of every 120, a quarter, which by arithmetic rings about half a second later on average (the iPhone announces itself about every 187 ms). A controller that cannot compare patterns by itself is not used: the kernel would then have to look at every Bluetooth advertisement nearby, awake, and the page says so.

**What it keeps.** Four two-byte numbers from your iPhone's announcement, the ones that are the same from one share sheet to the next (the iPhone shuffles their order and changes the rest each time), in `~/.local/state/nova/airdrop/phones`, readable by you alone. Nothing of any other phone is kept or logged.

Bluetooth must be on for it to hear anything; the page says when it cannot listen, and why.

**The Bluetooth chip resets itself.** On the P1 the Wi-Fi and Bluetooth share one chip. Once in testing, while AirDrop was busy on channel 6, its Bluetooth threw a hardware error and the kernel reset it; and with the doorbell on through a whole day, scanning at the kernel's half of the radio's time and through the night with the screen locked, it did so 34 times in 18 hours, more often in the afternoon, against none in 32 hours without the doorbell. Each time it is back a tenth of a second later and the doorbell goes on, but a device connected over Bluetooth (headphones) drops for that moment. Whether it still happens with the scan at a quarter and none while locked is not known yet; until it is, a doorbell that is not needed is better off.

**Measured** on the ThinkPad P1 Gen 4i with an iPhone 15 Pro: the computer is in the iPhone's list 1.2 s after AirDrop is switched on, a 1.0 MB photo arrives in 2.3 s, and the Wi-Fi is connected again 4 s after AirDrop ends. The speed is the iPhone's timetable: it is on the computer's channel in five of its sixteen slots while it sends, and in one while it only looks.

## Sending

1. **In Files:** select photos, videos or music, then right-click → Open With… → **AirDrop**. Any other file: `nova airdrop send <file>...` in a terminal.
2. **On the iPhone:** unlock it, and choose **Everyone for 10 Minutes** (Settings → General → AirDrop, or in Control Center: hold the network tile, then AirDrop).
3. **Pick it:** a window lists the iPhones nearby as they appear, by their names. Click one, or move to it with the arrows and press Return.
4. **It is asked, then sent:** a notification says it is waiting for the person there to accept, then shows the sending's bar, each with Cancel; then **Sent**, or that they declined.

AirDrop is switched on for the send if it was off, and goes off again after it, unless it was switched on meanwhile (from the menu, `nova airdrop on`, or for your iPhone's share sheet): the Wi-Fi is off the network meanwhile, as when receiving. Switched off during a send (the menu's row, `nova airdrop off`), it goes off at once and the send ends with it; the send's own Cancel ends just the send. Your iPhone's share sheet closing does not end a send. Bluetooth must be on: it is what wakes the iPhone's AirDrop.

**Why Everyone for 10 Minutes.** An iPhone set to Contacts Only takes AirDrop from its contacts alone, and checks who a sender is with an identity Apple issues to its own devices, which a PC cannot have. So it is not listed at all, or is listed as taking AirDrop from its contacts only and cannot be picked; the window and the command say what it needs. Everyone lasts ten minutes, then the iPhone goes back to Contacts Only by itself, so it is chosen again for each send. While no iPhone shows, the window says so.

- **Files, not folders**, up to 200 at a time, each under 8 GB. Not links or text.
- **Files' Open With has AirDrop for photos, videos and music**, the kinds Nova gives an app of its own: that way AirDrop is offered beside it and never becomes what opens a file. It is not in the launcher.
- **Escape, Cancel or a click beside the window stops it**, and so does Cancel on the notification, until the files have gone.
- **An iPhone that goes away as you pick it**, before it could be asked, brings the window back, saying so, with those still nearby; the command says so too.
- **Nothing picked, two minutes on:** AirDrop goes off, as it does after two minutes in which nothing was offered or sent, and the send ends with it, whoever switched AirDrop on. A notification says no one was nearby and what the iPhone needs, or, if an iPhone that could take the files was listed, that AirDrop went off before anything was sent. An iPhone being asked or sent to keeps it on.

### The command

| | |
|---|---|
| `nova airdrop` | how it is, in a line |
| `nova airdrop on`, `off`, `toggle` | switch it |
| `nova airdrop on --stay`, `off --stay` | on, and not ending after a transfer; and letting go of that on alone, which ends it only if nothing else holds it on (what the shell does for your iPhone's share sheet) |
| `nova airdrop accept`, `decline` | answer what is being offered |
| `nova airdrop available` | whether this computer's card can do it, and why not |
| `nova airdrop send <file>...` | send to an iPhone nearby: those that show are numbered as they appear; type one's number |
| `nova airdrop send --to <name> <file>...` | send to the iPhone of that name (or the only one whose name begins so) once it has been the only one of that name nearby for five seconds; with two, type the number of yours |
| `nova airdrop send --json`, `--window` | the same as lines of JSON, with `to <id>` or `cancel` on its input (what the shell runs); or in the shell's window (what Files runs) |
| `nova airdrop active` | succeeds while it is on (for scripts) |
| `nova airdrop watch` | each change as a line of JSON (what the shell reads) |
| `nova airdrop bell on`, `off` | the doorbell: your iPhone switches AirDrop on and off |
| `nova airdrop bell learn`, `forget` | learn an iPhone in the next minute; know none |
| `nova airdrop bell`, `bell watch` | how the doorbell is, in a line or as JSON |

`nova airdrop off` waits until the Wi-Fi has been handed back and says how that went, and so does `nova airdrop send` when it switched AirDrop on. Ctrl+C stops a send; it says Sent, declined, why it failed, or that no one was nearby, and succeeds only for Sent.

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
- **The receiver is not root.** It runs as you, with two capabilities, to open its socket on the radio and Bluetooth's management socket, and gives them up before it runs anything else. The Bluetooth socket is kept by a small process of its own, started first, which can do nothing but give the announcement that wakes an iPhone and take it away: the part that hears the air never holds it.
- **A send tells the iPhones nearby that this computer wants to send**, over Bluetooth, for as long as it looks and sends. The announcement has no Apple ID or name in it, but it goes out from the computer's Bluetooth address, the one it has for good: whoever listens nearby can tell this computer by it while it sends. With Bluetooth privacy on (`Privacy=device` under `[General]` in `/etc/bluetooth/main.conf`, then restart Bluetooth) the controller uses a random address that changes instead; Nova leaves that setting to you. Which iPhone it goes to is the one picked; what it sends is only what was given, read with your own rights (the command hands the daemon the files open).
- **AirDrop is all a phone can reach.** Its network lives in a namespace of its own, with one interface and one listening port: nothing else running on the computer (a printer queue, a login server, file sharing) is on that link.
- **It is on only while you want it.** Nothing starts it at login. With the doorbell on, your iPhone's share sheet does, and nobody else's.

## How it is built

For those working on it. The code is in `src/airdrop/`, and the shell's part (its notifications, the doorbell's rule, the send's window) in `src/shell/plugins/airdrop/`.

| Part | Is |
|---|---|
| `nova-airdropd` (`daemon/`, Rust) | the receiver and the sender: an AWDL node on the air, and AirDrop's HTTPS on top |
| `nova-airdrop` (`daemon/src/bin/`, Rust) | `nova airdrop`: switches it, answers it, watches it, hands it what to send |
| `nova-airdrop-radio` (`bin/`, bash) | lends the Wi-Fi card (`up`) and takes it back (`down`), as root |
| `nova-airdrop@.service` | runs `up`, then the daemon as the user who asked, then `down` however it ended |
| `nova-airdrop-apply` and `org.nova.airdrop` | the root half of on and off, through pkexec, with no password for the person at the computer |
| `nova-airdrop-bell` (`daemon/src/bin/`, Rust) | the doorbell: the Bluetooth controller listening for the user's iPhone |
| `nova-airdrop-bell@.service` | runs it as the user, from each login to its end, once `nova airdrop bell on` has enabled it; stops it before the computer sleeps |
| `nova-airdrop-bell-wake@.service` | starts it again once the computer is awake |
| `nova-airdrop.desktop` | AirDrop in Files' Open With: `nova airdrop send --window` |

**The radio.** `up` takes the Wi-Fi interface from NetworkManager and adds two interfaces to the card under one made-up address: `nova-cell`, an ad-hoc cell on channel 6 with AWDL's BSSID (`00:25:00:ff:94:73`), HT20, a beacon every ten seconds (an iPhone does not list a node whose cell beacons ten times a second); and `nova-mon`, a monitor interface. The cell is there for the card's hardware to acknowledge frames sent to that address. The frames themselves are heard and sent on the monitor. Announcements go out at 6 Mbit/s, which every radio in reach reads; data frames, to one iPhone close by, at 24 Mbit/s, and with four retries asked of the card in their radiotap (field 17): a frame given with a rate and no retries is sent once, and one the iPhone missed was then TCP's to send again, a second or more later. The first send to an iPhone (2026-11-17) stopped after its first 256 kB, its upload moving 31 frames in six seconds at 6 Mbit/s with no retries; this is the change that followed, not yet measured.

**The node** (`node.rs`, `wire.rs`). AWDL nodes announce themselves in action frames: a short one every 110 time units and a long one every second, carrying the node's clock, the channel it is on in each of sixteen slots, and whom it follows as master. The daemon announces a timetable of channel 6 in every slot. An iPhone that hears it answers pings, lists the service, and sends its data in the slots where its own timetable says 6: one slot in sixteen while idle, five once it is talking to somebody. The node keeps each peer's timetable and clock from its announcements and sends to a peer only while that peer is on the channel, holding frames until then.

**IP.** AWDL carries IPv6 between link-local addresses made from the nodes' addresses. The daemon makes a TAP interface, `awdl0`, in a network namespace of its own, and passes packets between it and the air: the kernel does TCP. The namespace is the daemon's alone (it takes a user namespace to make one without root), so nothing of the system listens on that link and nothing of the system reconfigures the interface. The daemon answers the kernel's neighbour questions itself, and mDNS for `_airdrop._tcp` (`packet.rs`).

**AirDrop** (`receiver.rs`, `http.rs`, `tls.rs`, `plist.rs`, `unpack.rs`). HTTPS on port 8771 with a certificate the daemon makes itself, on first use, in `~/.local/state/nova/airdrop`. A sender posts to `/Discover` and is told the computer's name; to `/Ask`, a binary property list of what it offers, and waits for 200 or anything else; then to `/Upload` on the same connection, one archive: cpio, packed either with gzip or, as iPhones do, in pieces that are each a zlib stream of their own. It is unpacked as it arrives into a hidden folder inside the downloads folder and moved into place when it is whole; a transfer that stops leaves nothing. The answer goes the moment the last byte is in, while the phone is still on the channel to hear it.

**Nothing but the system's libraries.** The daemon has no dependencies in cargo. TLS is the system's OpenSSL, loaded when the daemon starts; unpacking is the system's zlib.

**Talking to it** (`control.rs`). A socket in the user's runtime folder, `nova/airdrop.sock`. A client says one line (`watch`, `status`, `accept`, `decline`, `hold`, `stay`, `unstay`, `stop`); a watcher gets the state as a line of JSON at each change. The file's own comment has the states and their fields. `send` comes with the files to send passed open alongside it (`SCM_RIGHTS`, `meet.rs`), so the daemon reads what the user could and nothing else; the connection is that send's from then on (`send.rs` has its lines).

**Who holds it on** is the daemon's to know. `nova airdrop on` says `hold` (the user's, used up when a transfer to the computer ends), the shell says `stay` for the doorbell and `unstay` when the sheet closes (`nova airdrop on --stay`, `off --stay`), and a send holds it until it is over, or until its client has gone: a send cancelled while it is caught in something no shut connection ends (a file read from a network mount that went with the Wi-Fi) holds nothing. The doorbell's `unstay` lets go of its own hold and no more. `stop` is the user's off (`nova airdrop off`, the menu's row): the daemon ends at once whatever holds it, and a send under way ends with it, its client told. A daemon that is to end always can, as its own exit is what gives the Wi-Fi back. Started as the unit starts it (`--once`), it ends a moment after the last lets go, never while a transfer or a send is under way, and 15 seconds after it is up (its socket listening) if nobody takes hold of it at all (a command killed while it switched AirDrop on). Two minutes with nothing offered or sent (`--give-up-after`, counted again from each offer's end and each send's start and end) end it whoever holds it, and a send that is still looking with it; one that is asking or sending keeps it on until it is over. A send's last line says whether AirDrop stays on after it, which it never does once the daemon is ending. Once the daemon has decided to end it answers `hold`, `stay` and `send` that it is going off, and the command waits for it to go and starts it again. Ending is the daemon's own exit either way, so the Wi-Fi comes back as always: one `down`, from the unit's `ExecStopPost`.

**Sending** (`send.rs`, `wake.rs`, `sender.rs`, `pack.rs`). A send runs in three steps, all while the receiver goes on as before:

- **Waking the iPhone.** An iPhone keeps its AirDrop off the air until it hears, over Bluetooth, a device nearby announce that it wants to send: Apple's manufacturer data (`4c 00`), message `05`, the one the doorbell hears from an iPhone's share sheet. Its eighteen bytes carry four short hashes of the sender's Apple ID, phone number and addresses, for an iPhone set to Contacts Only to look up; Nova has none and sends zeros, which is why only Everyone works. The daemon's announcer gives the controller that advertisement while it looks and sends, and takes it away after. It is Bluetooth Low Energy, as the doorbell's listening is: with that switched off (Settings → Bluetooth), the kernel refuses the announcement, the send window says so with a button to Settings → Bluetooth, and the doorbell says it cannot listen. A thread of the send's own asks for it, the herald, so that a Bluetooth slow to answer (the announcer is given 13 seconds) holds up neither the list nor any of the limits below; the window's list waits for its first answer. It goes out from the controller's own address: the kernel gives an advertisement a random one only when it cannot be connected to, or when privacy is on for the whole controller, and no flag of the management interface asks for one otherwise (`net/bluetooth/hci_sync.c`).
- **Finding receivers.** While it sends, the node asks the air for `_airdrop._tcp` each second (mDNS, sent to the AWDL peers heard lately), reads where each receiver listens from the answers (`packet.rs`), and asks each `/Discover` who it is (`sender.rs`): its name, its model, and whether it takes AirDrop from this computer (a refusal there is a receiver that takes it from its contacts only). Those are the lines the window lists. A send keeps sixteen receivers at most, and two of one device: when a new one comes, the one the node heard of least lately makes room (one that would not say who it is before any other), never the one picked, so that a crowd that went quiet keeps nobody out. A pick of one that is not listed any more is answered at once with the list and the id that went (`gone`).
- **Asking and sending.** Picked, a receiver gets `/Ask`: a binary property list of the sender's name, model and id and each file's name, type and size. With it goes the picture the iPhone shows with the offer (`FileIcon`), JPEG 2000 of at most 540 pixels a side, as an iPhone sends its own: `nova airdrop send` makes it of the first file, a photo with `vips thumbnail` and a film's frame at its first second with `ffmpeg` where that is installed, reading the file through the descriptor it has open (so that no name is taken for vips's options), and hands it to the daemon last of the files, with `send icon`. A file that is neither, or one it cannot make a picture of within five seconds, goes without. It answers when its person decides, up to two and a half minutes later: 200 is yes, anything else no. Then `/Upload` on the same connection: the files as one cpio archive (the old portable format), gzip'd as it goes (`pack.rs`), in chunks. Each part has a limit, so that no receiver holds the Wi-Fi for long: 20 seconds to connect and say who it is, the person's two and a half minutes, 30 seconds at most with no progress while the files go and no less than 64 kB/s on average for all of them, beside a minute's slack (a receiver that takes a few bytes now and then is not let go on for ever; an iPhone receiving on one slot in sixteen, its idle timetable, would still go at about 90 kB/s by the measured receiving speed), and two minutes after the last byte for the answer (not measured with an iPhone and a large video: long enough not to call a send that arrived failed). Cancel shuts the connection, which ends any of them at once. While the files go, the daemon logs each second what the kernel's TCP says of the connection (what the receiver acknowledged of what went, what went again, the round trip, when it was last heard), and once more when a send fails: what tells a receiver that turned the files away from a link that lost them. The client side of TLS is the system's OpenSSL, as the server's, with the same certificate.

**Why Bluetooth's management socket, and not BlueZ, for the announcement.** BlueZ has a stable D-Bus interface for this, `LEAdvertisingManager1`, which can carry the bytes; it is not experimental and needs no capability. But it calls back into an object the advertiser serves on the system bus, and the daemon has no D-Bus: it would take a D-Bus library, or one written for it. The management socket (`MGMT_OP_ADD_ADVERTISING`, `mgmt.rs`, shared with the doorbell) needs `CAP_NET_ADMIN` at binding, and a socket bound so may tell the controller anything, so the daemon does not hold it (`announcer.rs`). Before it opens anything it forks the announcer, which closes all else, binds the socket, gives up every capability, and answers two requests over a socket pair, `announce` and `quiet`, each with a number its answer carries; it makes the announcement's bytes itself, reads and lets go of the socket's events so that their queue never fills, ignores the signals that end the daemon, and ends, quiet, when the pair closes. The daemon gives up its own capabilities once it has its socket on the radio, before it runs `openssl`. And `bluetoothd` does not know of the advertisement: the daemon takes the highest instance number free (`bluetoothd` hands out the lowest), and the advertisement lasts twenty seconds and is given again every eight, which also puts it back if anything took it away. A daemon that died leaves nothing announcing for longer than that.

**The notifications** (`src/shell/plugins/airdrop/`). The shell watches the daemon and sends Nova's notifications itself, with busctl: each word of what a sender calls itself and its files is one value there, never an option, and goes into the body escaped. The offer carries its Decline and Accept as the `nova-buttons` hint, commands the notifications run as they are; a transfer its bar as the standard `value` hint, in place under one id. A photo that came in gets a 256-pixel copy for its picture, made with `vipsthumbnail` with untrusted loaders blocked (`VIPS_BLOCK_UNTRUSTED`), since Qt reads no HEIC; one that cannot be made leaves the AirDrop glyph. The iPhone also sends a small picture with its offer, as JPEG 2000; it is not shown, since it would be decoding a stranger's file before the user said yes.

**The doorbell** (`nova-airdrop-bell`). It talks to the kernel's Bluetooth management socket, the one `bluetoothd` uses, and not to BlueZ: BlueZ's own interface for advertisement monitors is experimental, and switching it on would switch on other experimental parts too. Binding that socket takes `CAP_NET_ADMIN`, which the unit gives it; the kernel decides at binding what a socket may do, so it gives up every capability right after. It puts one advertisement monitor in place per iPhone it knows: four patterns, one for each of the iPhone's numbers in the first place of the announcement, any of which matches (the first place always holds one of them; an iPhone with fewer numbers is looked for in every place). Thresholds: found at once above -85 dBm, gone after 3 s below -95 dBm or unheard, told once a second meanwhile. While learning, a fifth monitor matches any iPhone's announcement (`4c 00 05` in Apple's data), and an iPhone louder than -65 dBm is the one learned. While something searches for Bluetooth devices (Settings' Bluetooth page), the kernel reports what a monitor matches as any device found, and those reports count too; an iPhone unheard for six seconds is gone, whatever the kernel said. A controller that goes off or away for a moment (the AX210 resets itself now and then) does not make the iPhone gone: for five seconds after, the kernel's "gone" waits for those six seconds. It notices Bluetooth switched off and on, the controller coming and going, and its monitors taken away, and puts them back; the monitors it put in place are noted in the runtime folder, so that a doorbell that died is tidied after. Before it puts its monitors in place it sets the kernel's scan for advertisement monitors to a 30 ms window every 120 ms (Default System Configuration types `0x0013` and `0x0014`, which are 60 and 30 ms unless set), and sets back what was there when none of its monitors is left (resting, forgotten, switched off). While it rests (the screen locked, said by the shell) it has none in place, and does not learn. A monitor the controller does not say it took away (no answer, as in one of the AX210's resets) stays noted and is tried again every ten seconds, so that none is left scanning. Its socket is `nova/airdrop-bell.sock` in the user's runtime folder: `watch`, `status`, `learn`, `forget`, `rest`, `wake`. The shell's AirDrop plugin does the rest (`Model.doorbell` in `AirDropModel.js`).

### Putting the Wi-Fi back

This is the part that must not fail, and `nova-airdrop-radio` is written round it:

- **The card's own address comes from the card** (`phy80211/macaddress`), never from the interface. NetworkManager puts a random address on a card while it scans, and takes the address a card has when it is handed back for the card's own: an early test script read the address during a scan, restored that, and the router refused the laptop until a restart.
- **What there is to undo is noted in `/run/nova-airdrop` before anything is changed**, and undoing takes the note first: it can be asked for twice and happens once.
- **Each step of the undoing is tried whatever became of the one before.**
- **Only `nova-cell` and `nova-mon` are ever deleted**, by name.
- **`down` is the unit's `ExecStopPost`**, which systemd runs however the daemon ended and when it never started. A daemon that hangs stops telling systemd it is alive and is ended (`WatchdogSec`).
- **`down` waits for NetworkManager to be connected again** where it was before, asks it outright after eight seconds, and says how long it took, or plainly that the Wi-Fi is not back. `nova airdrop off` prints that line.

### Trying it without a phone

- `cargo test -p nova-airdropd`: the frame formats against frames an iPhone answered, the unpackers, the HTTP reader, TLS against `openssl s_client`, the node against a made-up phone that keeps a timetable, the control socket, the doorbell's reading of an announcement and its patterns. For sending: the wake-up announcement's bytes, and the announcer's two requests and nothing else, over a socket pair with a made-up Bluetooth whose events it drains; who holds AirDrop on, and when the daemon ends; the mDNS question and the reading of its answers; the node asking while it sends and hearing a made-up receiver answer; the sender against Nova's own receiver on the loopback (TLS both ways, `/Discover`, `/Ask`, `/Upload`, and the archive unpacked by the receiver's own code, byte for byte); a declined and an unreachable receiver; a whole send, from the files handed over to Sent, over a socket pair; and the command's picker and its words.
- `tests/unit/airdrop/radio.bats`: `nova-airdrop-radio` against stand-ins for `iw`, `ip` and `nmcli`, with a card that shows another address than its own.
- `tests/qml/airdrop-test.qml`: the shell's part against stand-ins for `nova airdrop`, the notifications (busctl) and `vipsthumbnail`, the doorbell's rule and the send's window, picks and notifications among it.
- `tests/unit/airdrop/apply.bats`: the doorbell enabled for whoever asked, and nobody else.

### What is not there

- **Sending to an iPhone set to Contacts Only.** It takes an Apple identity.
- **Sending links, text or a folder**, and AirDrop in Files' Open With for documents.
- **Sending, measured.** It has been tried against Nova's own receiver only.
- **The 5 GHz channels.** An iPhone spends most of its slots on channel 44; Intel cards may not send there. Channel 6 is where every card may.
- **A picture of your own in the iPhone's list.** The iPhone draws the picture from the kind of computer the receiver says it is; a photo is shown only for a contact with an Apple identity.
