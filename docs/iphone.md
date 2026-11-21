# iPhone notifications

Your iPhone's notifications (Messages, WhatsApp, Mail, the calendar) can show on the computer as Nova's own, the way a watch gets them: over Bluetooth Low Energy, with nothing installed on the iPhone and no iCloud account.

**This is a preview.** It is built and tested against a simulated iPhone, but has not yet been tried with a real one. [Trying it](#trying-it) says what to look at if you do.

## Pairing, once

1. **Switch it on**: Settings → Bluetooth → **iPhone notifications**, or `nova notification iphone on`. Bluetooth and Bluetooth Low Energy must be on. For three minutes the computer can be paired, and the page counts them down.
2. **On the iPhone**: Settings → Bluetooth. Tap the computer under Other Devices, by the name the page gives.
3. **Compare the code**: the iPhone and a notification on the computer show the same six digits. If they match, Pair on both.
4. **Allow notifications** when the iPhone asks. The page then says **Connected**.

Missed step 4: on the iPhone, Settings → Bluetooth → ⓘ beside the computer → **Share System Notifications**.

## Every day

The iPhone connects by itself whenever it is near with Bluetooth on: after sleep, after you come back, after Bluetooth restarts. The computer never scans for it, which spares the Bluetooth chip.

| On the iPhone | On the computer |
|---|---|
| a new notification | a notification: the app, the title and the message |
| one delivered quietly (a Focus) | the history only |
| a call | nothing, ever |
| one read or cleared | its notification goes too |

A notification dismissed on the computer is cleared on the iPhone too; one that runs out by itself stays there. Do Not Disturb holds them like any other, and the lock screen shows none. The history (Super+Shift+Alt+comma) keeps the last ten.

| Command | Does |
|---|---|
| `nova notification iphone` | how it is, in a line |
| `nova notification iphone on`, `off` | switch it, for you alone |
| `nova notification iphone pair` | open the pairing window for three minutes |

## Privacy

- What a notification says goes to the shell alone; the journal records that one was shown, never what it said.
- Nothing pairs outside the three-minute window, and only with a code you compared. The iPhone is never trusted for audio or calls.
- The service runs fenced in: no network, the system and your home read-only.

## Trying it

```sh
journalctl --user -u nova-iphone-notifications -b
```

The journal says when it advertises, pairs, connects and shows a notification, and why when it does not. `could not subscribe` means Share System Notifications is off on the iPhone. With it on all day, `journalctl -k -b | grep -c 'Hardware error'` counts Bluetooth chip resets, which are worth reporting.

How it works, what it costs and its tests are in the [code's notes](../src/iphone/README.md).
