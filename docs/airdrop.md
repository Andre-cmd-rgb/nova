# AirDrop

An iPhone can send photos, videos, files and links to the computer with AirDrop, with nothing installed on the iPhone and no network in common: Nova speaks AirDrop over Apple's own radio link.

- **Receiving** has been tried on real hardware, an Intel AX210 with an iPhone 15 Pro.
- **Sending** to an iPhone is a preview: it is built, but its one real send stopped partway, and the change since has not been measured.
- **While AirDrop is on, the Wi-Fi is off its network**, and reconnects when AirDrop ends ([why](#why-the-wi-fi-goes)).

## Receiving

1. **Switch it on**: the menu's Toggle → AirDrop, or `nova airdrop on`. The bar's Wi-Fi icon becomes AirDrop's.
2. **On the iPhone**: Share → AirDrop. The computer appears under its name within a few seconds. Tap it.
3. **Accept**: a notification names the iPhone and shows what it offers. Unanswered, it is declined after 55 seconds.
4. **It arrives** in your Downloads folder, with a notification that opens it. Nothing there is ever replaced: a second `IMG_0412.HEIC` becomes `IMG_0412 2.HEIC`.

AirDrop ends by itself a moment after a transfer, or after two minutes with no offer; `nova airdrop off` ends it sooner. The Wi-Fi is back four or five seconds later.

### Let your iPhone switch it on

Settings → AirDrop → **Let my iPhone turn on AirDrop** (`nova airdrop bell on`). It learns your iPhone once: open Share → AirDrop on it, next to the computer, within a minute. From then on, tapping AirDrop in your iPhone's share sheet switches AirDrop on here, and closing the sheet switches it off. Somebody else's iPhone does not.

- It works only while the computer is unlocked, and never wakes it from sleep.
- It needs Bluetooth and Bluetooth Low Energy on. It listens through the Bluetooth chip, which on some Intel Wi-Fi cards resets itself now and then while listening, dropping Bluetooth headphones for a moment. If you see that, switch it off.

## Sending

1. **In Files**, select photos, videos or music, then right-click → Open With… → **AirDrop**. For any other file: `nova airdrop send <file>...`.
2. **On the iPhone**, unlock it and set AirDrop to **Everyone for 10 Minutes** (Settings → General → AirDrop). An iPhone set to Contacts Only checks who the sender is with an identity Apple gives only its own devices.
3. **Pick it** in the window that lists the iPhones nearby. A notification shows the person being asked, then the progress, then **Sent** or declined.

Files only, not folders or links; up to 200 at a time, each under 8 GB. Bluetooth must be on: it is what wakes the iPhone's AirDrop.

## The command

| | |
|---|---|
| `nova airdrop` | how it is, in a line |
| `nova airdrop on`, `off`, `toggle` | switch it |
| `nova airdrop accept`, `decline` | answer an offer |
| `nova airdrop available` | whether this computer's Wi-Fi card can do it, and why not |
| `nova airdrop send [--to <name>] <file>...` | send to an iPhone nearby |
| `nova airdrop bell on`, `off`, `learn`, `forget` | your iPhone switching AirDrop on |
| `nova airdrop watch` | each change, as a line of JSON |

## Why the Wi-Fi goes

A Wi-Fi card is on one channel at a time. iPhones talk AirDrop on channels of their own, hopping between them and their network many times a second, which a PC's card cannot follow while it stays on your network. So while AirDrop is on, the card is lent to AirDrop whole. A wired connection and Bluetooth are not touched, and going to sleep ends AirDrop.

## Which cards

`nova airdrop available` answers for this computer. The card needs to start an ad-hoc cell, give a monitor interface, and be allowed to send on channel 149 or 6. Cards with Linux's own Wi-Fi stack (mac80211) mostly can, but **only the Intel AX210 has been tried**. AirDrop takes channel 149 where the card may send there, and 6 where it may not; a drop-in for `nova-airdrop@.service` (`sudo systemctl edit nova-airdrop@.service`) with `Environment=NOVA_AIRDROP_CHANNEL=6`, or `149`, keeps it on one.

## What it lets in

- **While it is on, anyone in range sees the computer's name and can offer it something**, as with Everyone on an iPhone. Nothing is taken without your Accept, and one offer is taken at a time.
- What arrives is files and folders in Downloads, and nothing else: an archive's links, device files and paths that lead outside it are dropped.
- The receiver runs as you, not root, and AirDrop's network lives in a namespace of its own: nothing else on the computer is reachable from that link.
- Nothing starts it at login. With the iPhone switch on, your iPhone's share sheet does, and no one else's.

How it is built, how the Wi-Fi is handed back, and its tests are in the [AirDrop code's notes](../src/airdrop/README.md).
