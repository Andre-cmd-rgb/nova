# iPhone notifications: maintainer notes

The service that shows an iPhone's notifications as Nova's, through Apple's
Notification Center Service (ANCS) over Bluetooth LE (`daemon/`, Rust, D-Bus
through `nova-sd`), and its command (`bin/`). How to use it is
[docs/iphone.md](../../docs/iphone.md).

<!-- Moved from docs/iphone.md (RC15 docs rewrite): how it works, what it
     costs, the first real test and the tests, as they were. -->

## How it works

### Who connects to whom

An iPhone keeps ANCS for accessories it is bonded with, and it is the one that connects: the computer advertises, and an iPhone bonded with it connects as soon as it hears that. This is how watches stay connected, and others who have built ANCS on Linux report the iPhone back over LE a few seconds after the advertising starts again.

The other way round, the computer connecting to the iPhone, would have the computer listen for the iPhone's advertisements, which change their address every few minutes: that listening is **scanning**, and scanning is what crashes the Bluetooth firmware of the ThinkPad P1's Intel AX210 ("Hardware error 0x0c": 43 resets in 22 hours with AirDrop's doorbell scanning, none in 15 hours without). So the computer never scans for the iPhone. It only advertises, and only while a paired iPhone is away:

| When | Advertising | Its share of the radio's time |
|---|---|---|
| The iPhone connected | none | 0 |
| No iPhone paired, not pairing | none | 0 |
| For 30 s after the link drops, after a wake, after Bluetooth or its controller comes back | every 20-30 ms | about 6% |
| Then, until the iPhone is back | every 1285 ms | about 0.1% |
| The pairing window | every 100-150 ms, discoverable, with the computer's name | about 1%, for three minutes |

The intervals are Apple's: its accessory guidelines ask for 20 ms for the first 30 seconds, then one of a list of longer intervals, chosen not to fall in step with how an iPhone listens. 1285 ms is the longest of them, and a whole number of milliseconds, which is what BlueZ takes. The shares are by arithmetic: an advertising event is three short packets and a moment to hear a reply, about 1.5 ms of the radio. For comparison, the kernel's own listening for devices to connect is 30 ms of every 60 (read on the P1 with `btmgmt read-sysconfig`), and AirDrop's doorbell 30 ms of every 120. The kernel's default advertising interval on the P1 is 1.28 s.

**The connection's own cost** is the iPhone's to choose, as the one that connects: how often the two radios meet (the interval), how many meetings the computer may skip (the latency). BlueZ reports them; the service writes them into the journal at each connection, and they are in `nova notification iphone --json` as `link`. They have not been measured with a real iPhone yet.

**Sleep:** the kernel drops the connection and stops advertising as the computer goes to sleep. Nothing here wakes it. After the wake (logind's PrepareForSleep), it advertises fast again.

**BlueZ restarting, the controller resetting:** BlueZ forgets what was registered with it and lets the advertisement go; the service registers it again as soon as BlueZ or the controller is back. A registration BlueZ refuses is tried again after 5 s, then 10, doubling up to five minutes, so a controller that will not take it is not asked forever.

**What it keeps across a blip:** the notifications the iPhone had when the link dropped. A notification it has when the link comes back, under five minutes later, that was not among them and is dated after the drop, came in the gap and is shown. After a longer absence, a night asleep, those that came meanwhile are on the iPhone, and nothing is shown for them.

### Pairing, and what it lets in

- **A window, three minutes,** opened on request. Only then is the computer listed in the iPhone's Settings: the advertisement is discoverable, with its name. Bluetooth itself is not made discoverable, so BlueZ marks the advertisement Bluetooth LE only, and the iPhone pairs over LE.
- **Only then is there a pairing agent** with BlueZ, and with none BlueZ lets nothing pair: with no agent left, BlueZ turns the controller's bondable setting off (as main.conf's `AlwaysPairable` is off, BlueZ's default, which Nova keeps), and a pairing that reaches BlueZ finds no one to ask and is refused. The service unregisters the agent when the window closes, and also when BlueZ will not make it the default: a registered agent is asked all the same. The agent says it has a display and a yes/no, so the iPhone and the computer compare a code (LE Secure Connections' numeric comparison) rather than pairing unseen.
- **The agent says yes to nothing by itself.** A notification asks, with the code and the device's name as it sent it (plain text, its bidirectional characters taken out, cut at 64 bytes), and the buttons answer. Unanswered, the pairing ends with the iPhone's own 30 seconds. A pairing with no code to compare (Just Works), which an iPhone does not ask for, is turned down; so is a second device's while one is asked about, the first question standing; and so is any question from another program than BlueZ, as anyone on the system bus could call the agent.
- **The iPhone is never trusted.** Pairing over LE may give both sides a key for classic Bluetooth too, and an iPhone may then try the computer as a headset or a speaker: BlueZ asks the agent before it lets an untrusted device's audio or calls in, and the agent, while there is one, says no; with none, BlueZ says no itself. Calls stay on the iPhone.
- **One subscription is what asks to pair.** The service subscribes to ANCS only on an iPhone already paired, or during the window: the iPhone answers a subscription from a stranger by asking to pair.

### ANCS

The service subscribes to the iPhone's Data Source, then its Notification Source, as Apple's specification has it; the iPhone then lists the notifications it has (marked pre-existing) and each new one as it comes. For each new one it asks the Control Point for the app, the title, the subtitle and the message, at most 128, 128 and 320 bytes, the most two lines of title and three of message can show; and once per app, the app's name. The answers come back on the Data Source in pieces, which are put back together. One question is asked at a time, each given 5 seconds to be answered after the iPhone took it: a notification the iPhone has removed meanwhile is refused, and the next one goes on.

**What the iPhone sends is cut and cleaned here too.** The texts are cut at the lengths asked for before they are read, should anything send more; an answer longer than 8 KB is given up on. Format characters (Unicode's Cf), the bidirectional ones among them, which can make a text read other than it is, are taken out of titles, messages and names; the two joiners stay, as emoji and some scripts need them. Of a flood, the first 50 notifications waiting are followed and the rest passed over, and the service remembers no more than 1000 of the iPhone's notification numbers.

A notification here has a default action, so that a click is a dismissal: there is no window to bring forward for an iPhone's app. It carries Nova's `nova-iphone` hint, which its toast keeps in the history, so that a click on it there does not bring forward an app of this computer's that has the same name.

**A link back numbers anew.** The iPhone may give a notification's number to another one after the link drops. A toast from before the drop, dismissed after it, clears nothing on the iPhone: only the toast shown for a number now counts.

**Quietly delivered** ones carry the iPhone's silent flag, and go to the shell with Nova's `nova-quiet` hint: the history, no toast. **Dismissed** ones (the shell says so when it closes a notification) are cleared on the iPhone with the notification's negative action, where the iPhone offers one. The shell closes a notification as *expired* when it ran out, went straight to the history under Do Not Disturb, or left the screen for the history's replay: none of those clears it on the iPhone.

## Privacy in detail

- **What a notification says goes to the shell alone.** The service logs that something was shown, never what.
- **The history** keeps the last ten notifications gone, the iPhone's as any app's, in `~/.local/state/nova/notifications/`.
- **The service's state** (the iPhone's name and Bluetooth address, for Settings) is in `$XDG_RUNTIME_DIR/nova/iphone-notifications.json`, readable by you alone. It goes when the service stops, however it stops (a crash too: the unit removes it), and at logout. Settings believes it only while the service runs, says **Starting…** while systemd starts it, and otherwise **Not running**.
- **The service is fenced in** by its unit: no network but the D-Bus sockets, the system read-only, the home folder read-only, a /tmp of its own, no capabilities, the system calls of a service only. It can write its folder in `$XDG_RUNTIME_DIR` and nothing else.
- **Everything goes over the Bluetooth link**, encrypted with the key of the pairing.

## What it costs

- **Memory:** under 1 MB (PSS 0.85 MB with no iPhone, 0.94 MB connected after twenty notifications, against a fake BlueZ). The Python program it was until 1.0 took 19 MB.
- **The processor:** nothing at all while nothing happens: no wakeup in a minute, waiting or connected. Nothing runs on a clock: it waits for BlueZ, the shell and logind to say something changed.
- **The radio:** the table above.
- **Built in Rust** (`src/iphone/daemon`), with D-Bus from the system's libsystemd through Nova's `nova-sd`. The service itself (`service.rs`) speaks no D-Bus: the glue (`main.rs`) hands it each message and makes each call it asks for, never waiting for an answer, as BlueZ calls back before it answers some.

## Trying it the first time

After installing a Nova with it:

1. Settings → Bluetooth: Bluetooth on, Bluetooth Low Energy on, then **iPhone notifications** on.
2. On the iPhone: Settings → Bluetooth. Find the computer under Other Devices, by the name the page gives, and tap it.
3. Compare the codes and Pair on both; Allow notifications on the iPhone.
4. Send yourself a message from another phone, or have someone send one: it shows at the top right.
5. Then, one at a time, and look whether it comes back by itself (the page says Connected): lock the computer and unlock it; put it to sleep for a minute and wake it; turn the iPhone's Bluetooth off and on in its Settings (not the Control Center, which only disconnects for a while); walk away with the iPhone and come back.

Each step, if it does not do what it should, the journal says why:

```
journalctl --user -u nova-iphone-notifications -b
```

| The journal says | It means |
|---|---|
| `advertising (pairing, every 100-150 ms)` | the window is open: the computer should be in the iPhone's list |
| `could not advertise: …` | BlueZ refused the advertisement (Bluetooth LE off, no controller) |
| `pairing agreed to`, `pairing turned down` | the notification's buttons |
| `… did not pair (…)` | the pairing failed or was cancelled |
| `turned down a pairing with no code to compare` | a device asked to pair unseen (Just Works); an iPhone should not, so say if one did |
| `turned down a second pairing while one is asked about` | two devices tried at once |
| `could not make the pairing agent BlueZ's: …` | BlueZ refused the agent: the window closed again |
| `… connected: interval 30 ms, latency 0, supervision timeout 720 ms` | the iPhone connected, and the radio's cost of it |
| `could not subscribe to …` | connected, but no notifications shared: Share System Notifications on the iPhone |
| `notification 1234 shown`, `… shown quietly` | one came, and went to the shell (what it says is not logged) |
| `notification 1234 dismissed here: cleared on the iPhone` | dismissed on the computer |
| `more than 50 notifications at once …` | a flood: the rest of it was passed over |
| `… went away` then `advertising (fast, …)` | the link dropped, and it waits for the iPhone |
| `org.nova.iPhoneNotifications is another program's already` | a second copy was started; the unit does not try again |

And whether the Bluetooth chip resets itself, which is what to keep an eye on with it on all day:

```
journalctl -k -b | grep -c 'Hardware error'
```

Should the iPhone never come back by itself, `sudo btmon` while it should shows whether the computer advertises and whether the iPhone tries at all; its output holds both devices' addresses, so it is not one to share.

## Tests

`tests/unit/iphone/`, and the crate's own (`cargo test`):

- **ANCS byte for byte** (`ancs.rs`'s tests): the events, the three commands and the answers, from fixtures built from Apple's specification, none from a phone; answers in pieces of every size, with the end of an answer given up on in front, and one too long; texts cut in the middle of a character and past their limits, and cleaned of bidirectional and other format characters.
- **The service** (`src/iphone/daemon/tests/`, run by `cargo test`): the real service on a D-Bus of its own, against a fake BlueZ with a fake iPhone behind it and a fake notification server. The fake BlueZ answers a pairing as BlueZ does: refused with no agent registered, asked of an agent with a code (RequestConfirmation) or without (RequestAuthorization). Pairing (the advertisement, the agent, the code in a notification, the answer coming after the notification closed, a code turned down and not asked again), pairings asked by others (no agent outside the window, an agent BlueZ will not make the default unregistered, Just Works turned down, a question from another program than BlueZ, a second device while one is asked about, a device's name with bidirectional characters), new, quiet, removed, dismissed and expired notifications, calls, a refused command, a link back after a blip, a toast from before a drop whose number the iPhone gave to another, an iPhone that keeps to no limit and a flood, BlueZ restarting, the controller resetting, Bluetooth off, Bluetooth LE off, a late answer of the BlueZ before a restart, BlueZ restarting while a pairing is asked about, a toast dismissed while its change was on its way, old notifications that look new after a link back, the service's name taken.
- **The command** (`cli.bats`); Settings' switch and line, also with the service stopped (`tests/qml/iphone-settings-test.qml`); a click on an iPhone's toast in the history (`tests/qml/notifications-click-test.qml`).
- **The unit's fence**, checked by hand on a transient unit with the same settings (not part of `make test`): the session and system buses through their sockets, its runtime folder written and nothing else, no network sockets, and the service itself against the fake BlueZ inside it. That was the Python service's; the Rust one has not been run inside the fence yet. Every system call it imports is one `SystemCallFilter=@system-service` allows (its `nm -D` against `systemd-analyze syscall-filter`), and it writes only its state file in the runtime folder.
