# Hardware compatibility

**Verified** = tested by the maintainers on real hardware. **Unverified** = implemented from the
public specification or the manufacturer's manual, covered by unit tests, but not yet tested on
the device. Reports are very welcome: open a
[hardware report](../../../issues/new?template=hardware-report.yml).

## DMX outputs

Choose the output in Setup → Rete → **Uscita DMX**. Art-Net is the default.

| Output | Devices | Status | Notes |
|---|---|---|---|
| Art-Net 4 (ArtPoll discovery, unicast ArtDmx) | ENTTEC ODE MK3 | ✅ Verified | Reference setup |
| Art-Net 4 | Other Art-Net nodes | 🟡 Unverified | Should work; ENTTEC nodes are auto-selected |
| sACN / ANSI E1.31 | Any E1.31 receiver | 🟡 Unverified | Multicast 239.255.x.y or unicast; priority 0–200; source name "RAYS"; Art-Net 0 → sACN 1 by default (switchable to Art-Net 1 → sACN 1). No universe discovery or synchronization packets |
| ENTTEC DMX USB Pro protocol (label 6) | ENTTEC DMX USB Pro, DMXking ultraDMX Pro / Micro and other compatible widgets | 🟡 Unverified | Appears as `/dev/cu.usbserial-*` with macOS's built-in FTDI driver. One universe |
| ENTTEC Open DMX USB | — | ❌ Not supported | See below |

**Why not Open DMX USB.** The Open DMX USB has no microcontroller: the computer must generate the
DMX signal itself (250 kbaud, 8N2, a break of at least 88 µs and a mark-after-break before every
frame, refreshed continuously). macOS's built-in FTDI serial driver can set the baud rate and send
a break, but their timing then depends on user-space scheduling and the FTDI latency timer, which
can only be tuned through FTDI's proprietary D2XX library. Without it the frames are not reliable
enough for a live show (flicker, dropped channels), so RAYS does not offer it. Interfaces with
their own processor (DMX USB Pro protocol, Art-Net, sACN) are recommended.

## Fixtures

All fixture profiles are JSON files in `Profiles/` (see [Add a fixture](adding-a-fixture.md)).
Strobe, macro, programme, sound and UV channels are always kept at 0.

The Open Fixture Library import (`Scripts/import-ofl.py`) only takes modes with RGB channels
whose other channels are harmless at 0 (or a shutter with a documented "open" value, which is
held there). Modes where 0 would select a colour macro, an effect or an undocumented strobe are
skipped, as are moving heads, scanners, lasers and fog machines.

| Fixture | Modes | Status |
|---|---|---|
| Varytec Retro Blinder TRI 180 | 5 ch, 8 ch | ✅ Verified |
| Varytec Retro Blinder TRI 380 | 5 ch, 25 ch | ✅ Verified |
| Varytec Event Par IP65 4in1 14x8W | 4, 7, 9 ch | 🟡 Unverified (official manual) |
| Varytec LED Pad 7 7x10W 5in1 RGBWA | 5, 6, 9 ch | 🟡 Unverified (official manual) |
| Varytec LED Pad 7 7x10W 6in1 RGBWAUV | 6, 7, 10 ch | 🟡 Unverified (official manual; UV kept at 0) |
| Generic RGB, RGBW, Dimmer+RGB, Dimmer+RGBW | | ✅ Built in |
| ~110 fixtures from American DJ, Ayra, BeamZ, Cameo, Chauvet DJ, Elation, Eurolite, Fun Generation, Martin, Showtec, Stairville, Varytec | ~320 modes | 🟡 Unverified, converted from the [Open Fixture Library](https://open-fixture-library.org) (`Profiles/ofl/`) |
| Generic RGBA, Dimmer+RGBA, RGBWA, Dimmer+RGBWA, Dimmer+RGBWA+UV, 2-zone RGB bar | | 🟡 Generic profiles |

## MIDI controllers

| Controller | Status | Notes |
|---|---|---|
| Allen & Heath Xone:K2 (Classic, Live v2) | ✅ Verified | Built-in layouts, LED feedback, on-screen guide |
| Controllers with a layout in `Controllers/` | 🟡 Unverified | Routed from JSON; LED feedback when described ([guide](adding-a-controller.md)) |
| Any other MIDI controller | ✅ | MIDI Learn; enable "listen to all MIDI inputs" in Setup |

## Tempo

| Source | Status | Notes |
|---|---|---|
| Ableton Link | ✅ Verified | Always on |
| Pioneer Pro DJ Link (CDJ / XDJ) | ✅ Verified | Via the bundled Beat Link helper; beats feed the Link timeline |
| MIDI Clock (24 ppqn, Start/Stop/Continue, Song Position) | 🟡 Unverified | Opt-in beat source; listens to every MIDI input; beats feed the Link timeline |
| Internal clock / tap tempo | ✅ | |
