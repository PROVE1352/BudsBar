**English** | [한국어](README.ko.md)

# BudsBar

A native macOS menu bar app for changing **Galaxy Buds4 Pro** settings from a Mac, without a Samsung phone.
Swift + SwiftUI (`MenuBarExtra`) + IOBluetooth RFCOMM. English and Korean UI (follows the system language).

> **Unofficial project.** BudsBar is not affiliated with, endorsed by, or supported by Samsung.
> "Galaxy Buds" is a trademark of Samsung Electronics. Use at your own risk.

## What it does

- Shows battery (left / right / case), wear state and charging.
- Changes the earbud settings listed below and keeps the panel in sync by decoding the status messages the
  buds push after every change. (Seen for changes made by BudsBar; changes made by touch or from a phone
  arrive through the same messages but were not tried by hand.)
- Starts at login and stays quiet: while the Buds are not connected it holds no RFCOMM channel, runs no
  timers and does no polling; it only waits for IOBluetooth connect / disconnect notifications. The menu
  bar icon is hidden while the Buds are away and appears when they connect.
- Includes a debugging CLI (`BudsBar --cli …`) with raw frame send and hex dump.

## Feature status

Tested on one Galaxy Buds4 Pro (SM-R640, firmware R640XXU0AZD2, status revision 4) with macOS 26 on Apple Silicon.

- **Verified**: the buds acknowledged the command *and* the change showed up in the status message they report back.
- **ACK only**: the buds acknowledged it, but nothing in the status message reflects it, so the effect could not be confirmed.
- **Not tested**: implemented but deliberately not exercised.
- **Unavailable**: shown disabled in the UI with the reason.

| Feature | Status | Notes |
|---|---|---|
| Battery L/R/case, wear state | Verified | Case battery reads 0 while both buds are out of the case; shown as "No data" |
| Charging indicator | Works | Status offset 43; confirmed by the user on a real device |
| Noise control: Off / ANC / Ambient / Adaptive | Verified | Adaptive is `NOISE_CONTROLS [3]` |
| Ambient level (5 steps) | Verified | |
| ANC level (0–4) | ACK + stored | The value is stored and reported back; the audible difference was not checked |
| EQ presets | Verified | |
| Custom 9-band EQ | Verified (mode) | Band table is stored on the Mac and re-sent after every noise-control change, because the buds drop it. The band values themselves cannot be read back |
| L/R balance | Verified | |
| Conversation detection on/off | Verified | |
| Conversation detection timeout | ACK only | |
| Noise control with one earbud | Verified | |
| Ambient customization (L/R level, tone) | Verified | |
| Sidetone | Verified | |
| Per-gesture touch allow (single/double/triple pinch, pinch & hold, swipe, call gestures) | Verified | Buds4 Pro needs the 8-byte `LOCK_TOUCHPAD` payload (8th byte = swipe) |
| Lock all touch controls | ACK only | Not mirrored in the status message |
| Pinch & hold action, left / right | Verified | |
| Noise-control cycle (which modes pinch & hold cycles through) | Verified | Including Adaptive |
| Pause when an earbud is removed (wear detection) | Verified | |
| Call path control, seamless connection, extra clear call, Speak seamlessly, siren detection | Verified | |
| Bixby voice wake-up | ACK only | |
| Find my earbuds: ring | Works | Confirmed by the user on a real device. Stop and per-side mute were tested too |
| Firmware / serial / model info | Verified | |
| Auto-connect when the Buds connect | Verified | |
| Reconnect after the Buds leave and come back | Works | Icon hides when the Buds go into the case and reappears on reconnect; confirmed by the user |
| Game mode | Unavailable | The buds neither acknowledge nor apply `GAME_MODE (0x87)` |
| Adaptive volume | Unavailable | No response to `0xC5` |
| Auto-answer calls, double pinch & hold | Unavailable | No known command |

The menu bar panel was checked by rendering every page offscreen (`--cli snapshot`). Its controls call the
same code paths as the CLI commands above, but they were not clicked through by hand.

### Not possible from a Mac

These features run on a Samsung phone (or need one), so BudsBar cannot offer them:
360 Audio / head tracking, UHQ (24-bit) audio and the Samsung Seamless Codec, Interpreter / live
translation, firmware updates, SmartThings Find, and Bixby itself.

BudsBar also never sends factory reset, reboot / power-off, firmware-update (FOTA), test-mode or
pairing-mode commands; these IDs are blocked in the transport, including from `--cli raw`.

## Build and install

Requires macOS 14+ and Swift 6 (Xcode command line tools). Apple Silicon is the tested target.

```sh
git clone https://github.com/PROVE1352/BudsBar.git
cd BudsBar
./build.sh
```

`build.sh` builds a release binary, wraps it in `BudsBar.app` (with `LSUIElement` and
`NSBluetoothAlwaysUsageDescription`), signs it ad hoc and installs it to `~/Applications/BudsBar.app`.
Open it once; macOS asks for Bluetooth permission. Because the signature is ad hoc, macOS may ask again
after a rebuild. BudsBar registers itself as a login item on first launch; you can turn that off in
the panel (More → Launch at login).

The icon is hidden while your Buds are disconnected. To reach the panel anyway, launch the app again
(it then shows the icon until it quits) or turn on "Show menu bar icon even without Buds".
To pin a specific pair: `defaults write io.github.prove1352.BudsBar deviceAddress xx-xx-xx-xx-xx-xx`.

## CLI

Run the binary inside the bundle (only one process can hold the RFCOMM channel, so quit the menu bar app first):

```sh
B=~/Applications/BudsBar.app/Contents/MacOS/BudsBar
$B --cli status           # decoded state + firmware
$B --cli -v nc adaptive   # change noise control, print every frame
$B --cli raw 78 01        # send msgId + payload, print the replies
$B --cli dump 30          # hex dump of everything received for 30 s
$B --cli esu              # raw status payload with offsets
$B --cli selftest         # offline frame / CRC test vectors
$B --cli help             # all commands
```

## Protocol notes

Frames are `FD [size|flags LE] [msgId] payload [CRC16-XMODEM LE] DD` on the Samsung SPP service
`2e73a4ad-332d-41fc-90e2-16bef06523f2`. Things that differ from the GalaxyBudsClient decoder on the Buds4 Pro:

- Extended status (`0x61`, 62 bytes): ambient tone is at offset 36 (not 31), extra clear call at 44 (not 43),
  auto pause at 46 (not 45), siren detection at 52.
- Noise-control cycle (`0x79 [L][R]`, status offset 21 = `L<<4 | R`): bit 0 ambient, 1 adaptive, 2 off, 3 ANC.
  The ACK is 3 bytes (`79 L R`).
- `LOCK_TOUCHPAD` takes 8 bytes; the touch-lock bits are at status offset 10 (bit 0 hold, 1 triple, 2 double, 3 single,
  4 call double, 5 call hold, 6 swipe).
- The upper header bits change from frame to frame (they look like a sequence counter), so the "type" bit is not
  meaningful; BudsBar uses only the low 10 bits (size).
- Firmware strings arrive unsolicited in `0x68` (left / right, 20 bytes each).

## Credits

The protocol knowledge comes from [GalaxyBudsClient](https://github.com/timschneeb/GalaxyBudsClient)
by Tim Schneeberger and contributors (GPL-3.0). BudsBar is a separate Swift implementation, but because it
is derived from that work it is released under the same license. Thank you.

## License

[GPL-3.0](LICENSE)
