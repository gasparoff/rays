# RAYS user guide

RAYS plays lighting choreographies on real DMX fixtures, in time with the music. It takes the tempo
and the downbeat from Ableton Link, Pioneer Pro DJ Link or MIDI Clock, and sends DMX over Art-Net,
sACN or a USB DMX interface. This guide takes you from a fresh install to a show.

- [Install](#install)
- [First launch without lights](#first-launch-without-lights)
- [Connect your DMX output](#connect-your-dmx-output)
- [Patch your lights](#patch-your-lights)
- [Choose the beat source](#choose-the-beat-source)
- [Play a show](#play-a-show)
- [Arrange the Live window](#arrange-the-live-window)
- [Edit scenes](#edit-scenes)
- [Controllers](#controllers)
- [Keyboard shortcuts](#keyboard-shortcuts)
- [Where your data lives](#where-your-data-lives)
- [Troubleshooting](#troubleshooting)

## Install

Download `RAYS-<version>-macOS-arm64.zip` from the
[latest release](https://github.com/gasparoff/rays/releases/latest), unzip it and move **RAYS.app** to
Applications. RAYS needs macOS 14 or later on Apple silicon.

From 0.2.0 releases are signed with a Developer ID and notarized by Apple: RAYS opens with a double
click, and Pro DJ Link is built in, with nothing else to install. With 0.1.0, which is not notarized,
macOS says it can't check the app: open System Settings → Privacy & Security once and click
**Open Anyway**. You can check any download against its SHA-256 file and build attestation, as
described in [SECURITY.md](../SECURITY.md).

The first time RAYS looks for lights or consoles, macOS asks for permission to use the **local network**.
Allow it: Art-Net, sACN, Pro DJ Link and Ableton Link all need it.

To build from source instead, see the [Quick start](../README.md#quick-start).

## First launch without lights

RAYS opens on the **Live** window with the output off and the show stopped: the last scene is
selected but nothing moves until you press **Play** (or a scene pad). **Pause**, next to Play in
the top bar and in the performance panel, fades to dark and keeps the scene for the next Play. The stage preview draws your lights from the
exact DMX values RAYS would send, so everything in this guide works without any hardware: you can
learn the app and design scenes on a laptop.

The status at the top tells you what the output is doing:

| Status | Meaning |
|---|---|
| **Output off · preview only** | Nothing goes on the wire. The preview still plays. |
| **Output on** | DMX is sent to the interface chosen in Setup. |
| **BLACKOUT** | Every channel is at zero, whatever the scene. |

**Lights on** (or Space) turns the output on; **Lights off** turns it off. RAYS remembers the choice for
the next launch. Editing the patch or switching to another interface turns the output off, so a change
in Setup never lights up a stage by surprise.

## Connect your DMX output

Open **Setup → Network** and pick a **Protocol**:

- **Art-Net** (default) for an ENTTEC ODE MK3 or any Art-Net node. RAYS discovers nodes on the network
  and lists them under *ENTTEC nodes found*; choose yours with **Use this one**, or **Use manual IP** if
  discovery is blocked. **Web page** opens the node's own configuration page.
- **sACN (E1.31)** for receivers that speak it, in **Multicast** or **Unicast**. Choose how Art-Net
  universe numbers map to sACN (Art-Net 0 → sACN 1, or the same number).
- **DMX USB Pro** for ENTTEC DMX USB Pro and compatible widgets (DMXking ultraDMX Pro/Micro). ENTTEC
  Open DMX USB is not supported: [docs/hardware.md](hardware.md#dmx-outputs) explains why.

Changing protocol turns the output off. Turn it back on when you're ready.

**Mac straight to the node with a cable, no router?** Choose the Ethernet **Adapter**. If the node sits
on 192.168.0.x, RAYS can add the single address 192.168.0.20/24 to that adapter; macOS asks for an
administrator password. DHCP, Wi-Fi, DNS and the gateway are left alone, and **Remove the lights
address** takes it away again. With a switch or a router you don't need this.

## Patch your lights

Open **Setup → Lights**. The patch is the list of your fixtures: for each one a **Profile** (brand,
model and DMX mode), a DMX **Address** and an Art-Net **Universe**.

1. Under **Add lights**, pick each fixture's **Profile** (around 320 modes from 112 lights are built in),
   its universe and address, and **Add** it. **Quick presets** fill the reference Varytec rig in one click,
   with the line to copy onto each light, such as *Mode → DMX, CH Mode → 08CH, Address → 008*.
2. Set the address exactly as it is on the fixture's display, and set the fixture to the same DMX mode
   (channel count) as the profile. The editor refuses fixtures whose channels overlap in a universe.
3. **Quick test · 5 seconds**: **Solid red** or **Warm white** confirms the address and the mode on the
   real light. Tests never clear a blackout.
4. Tick **The lights are set like this (Mode DMX, CH Mode, Address)** and **Save**. Any later change
   clears the tick, so a patch that wasn't checked on the lights is never sent.

Your light is missing? A profile is one JSON file: see [Add a fixture](adding-a-fixture.md). You can
also build one in the app with **Create profile**, choosing what each channel does. Fixtures' internal
strobe, macro, program and sound-to-light channels are never driven by RAYS.

RAYS lays the rig out on three positions today (left, center, right) and every scene is written for
them. Support for any number of groups placed freely on the stage is being built
([ADR 0005](adr/0005-flexible-rig-model.md)).

## Choose the beat source

Open **Setup → Controller** and choose the **Beat source**:

- **Automatic** (recommended): RAYS joins the **Ableton Link** session (Traktor, rekordbox, djay,
  Ableton Live, Serato and many more) and, if it finds Pioneer CDJ/XDJ consoles on the network, follows
  the master deck over Pro DJ Link through the bundled Beat Link helper. **Auto master** follows
  whichever deck is master; you can pin **Deck 1** or **Deck 2** instead.
- **Link only**: Ableton Link without the console connection.
- **Console**: Pro DJ Link only.
- **MIDI Clock** (experimental): RAYS listens to MIDI Clock on every MIDI input; Start marks the first
  beat of the bar.

With no source at all, the internal clock runs. Set it with **TAP**, the arrows next to the BPM, or by
typing a value.

Tempo shows at the top of the Live window, with four beat marks. If the lights hit on the wrong beat of
the bar, press **R** (or ↺) on the downbeat: the running scene restarts from its first beat. Ableton Link's
tempo and phase are not changed.

## Play a show

The Live window holds everything you touch during a set.

**Scenes.** Six scenes per bank, on keys **1–6**:

| Key | House bank | Club 130–138 bank |
|---|---|---|
| 1 | Amber · warm breath | Club · 3+3+2 bass |
| 2 | Sunset · offbeat groove | Club · clave and swing |
| 3 | Pulse · tech house 3+3+2 hits | Garage · call and response |
| 4 | Chase | Rave · chase 136–138 |
| 5 | Build | Build · 8 beats |
| 6 | Drop | Impact · long tail |

Pick the bank above the scene buttons. The **+** next to them adds a bank of your own that starts from
the House or Club scenes; edit its pads like any other, and right-click it to rename or delete it.
Changing bank doesn't start a scene or change the tempo. A new
scene starts on the beat, so changes always land in time: a ring on the queued button fills until it
starts.

**Command search** (⌘K): type a few letters of a scene or an action (blackout, lights, banks, layouts,
Setup) and press Return.

**Performance controls:**

- **Master brightness**: everything, warm light included. At 0% no light comes out.
- **Warm light**: intensity of the white COB, independent of the colors.
- **Energy**: movement, contrast and accents of the choreography. It is not a second dimmer.
- **Left / Center / Right levels**: dose each position.
- **Movement speed**: ¼×, ½×, 1× or 2× of the tempo.
- **Flash (hold)**: a burst of warm light while you hold, two seconds at most.
- **Build → Drop (hold)**: hold during the build, release on the drop. The drop lands on the beat.
- **Stop**: fades to dark in one beat. Select a scene to start again.
- **Blackout** (**Esc** or **B**, always in the top bar): every channel to zero, immediately, and a red
  frame around the window. Esc always means blackout; B or a click resumes. Blackout survives a relaunch.

Under the tempo, the **scene miniature** shows the running scene's tracks and where the playhead is.
Click it to open that scene in the editor.

RAYS keeps the Mac awake while the output is on (the screen may still sleep) and reconnects to the same
interface by itself if it drops.

## Arrange the Live window

Press **Layout** to rearrange the window on a 12-column grid: drag a panel by its handle onto another to
swap them, drag its edge to resize, hide what you don't use. **Presets** give you *Classic*,
*Tempo on the right*, *Big stage* and *Minimal*. The layout is saved. The performance panel with
Blackout can't be hidden.

## Edit scenes

The pencil on a scene (or **Edit scene…**) opens the full-window editor. Built-in scenes keep their
originals: your changes are saved as an edited version (**EDITED**), and **Restore original preset…**
brings the factory one back. **Make a personal copy…** turns a scene into one of your own.

- The **rhythm grid** shows up to eight tracks on a shared time axis. Each track has its own step
  (1/4, 1/8, 1/16) and cycle; short cycles repeat. Click a cell to cycle strong → soft → off, drag to
  paint.
- The **inspector** on the right sets what the selected track does: **Lights** (which positions, RGB or
  warm light, segments, movement, direction, offset and color), **Hit** (envelope: attack, hold, release,
  floor and peak), **Timing** (push, pull, ramps) and **Mix** (how tracks combine, how soft hits follow
  Energy).
- **Scene settings** hold the name, palette, energy, speed, white and the three levels.

Nothing is written until **Save** (⌘S). **Cancel** (⌘.) restores the engine as it was; ⌘Z and ⇧⌘Z undo
and redo. The editor never turns the output on, but if it is already on, the lights follow your edits.

## Controllers

Open **Setup → Controller**.

- **Allen & Heath Xone:K2**: detected automatically, with LED feedback. Choose the **Classic** or
  **Live v2** layout; the guide on screen shows every assignment. Set the K2 to *Latching Layers OFF*.
  Faders use soft takeover: they act once they reach the value on screen.
- **Akai APC40 mkII**: layout from Akai's published protocol.
- **Other MIDI controllers**: any controller described in `Controllers/` gets its layout and on-screen
  guide automatically. For anything else, turn on *Listen to every MIDI input for “Learn”*, press
  **Learn** next to an action and move the control. Learned controls always win over a built-in layout.

A controller layout is one JSON file: see [Add a controller](adding-a-controller.md). Choosing scenes,
learning and plugging in a controller never turn the output on.

## Keyboard shortcuts

| Key | Action |
|---|---|
| Esc | Instant blackout |
| B | Blackout on/off |
| Space | Lights on/off |
| 1–6 | Scenes of the visible bank |
| R | Restart the scene from its first beat (align the downbeat) |
| ⌘K | Command search |
| ⌘S | Save in the editor |
| ⌘. | Cancel the editor, close Setup |
| ⌘Z / ⇧⌘Z | Undo / redo in the editor |

## Where your data lives

Everything is plain JSON in `~/Library/Application Support/RAYS/` (older versions used
`Light System/`; RAYS moves it on first launch): `patch.json`, `preferences.json`, `midi.json`,
`custom-scenes.json`, and your own `Profiles/` and `Controllers/`. Files are written atomically. A file
that can't be read is kept aside as `<name>.unreadable.json` and reported in Setup, never overwritten.
Setup shows the exact folder (*Data saved in …*).

RAYS has no account, no analytics and no update check. It only talks to your local network and, for
Ableton Link, to the apps in the same Link session.

## Troubleshooting

**The preview moves but the lights don't.** Check that the status says *Output on* and not blackout.
In Setup → Network, check that the node is selected and reachable (**Web page** should open). Check that
the universe in the patch matches the node's output port, and that the fixture is in DMX mode with the
same channel count as its profile.

**Colors are wrong or a light does something else.** The DMX mode on the fixture doesn't match the
profile, or two fixtures overlap. Run the 5-second test on each light.

**No node is found.** Discovery uses broadcast: some managed networks block it. Use **Use manual IP**,
or connect the Mac directly to the node.

**Pro DJ Link sees no console.** Mac and consoles must be on the same network (a switch is enough).
Close other apps that use Pro DJ Link ports, such as Beat Link Trigger or rekordbox's Link features;
RAYS reports a port conflict. Only builds made from source without the Beat Link helper lack Pro DJ Link.

**The lights are a beat late or early.** Press **R** on the downbeat. If they are consistently late,
check the latency compensation of your DJ software's Link settings.

Still stuck? Ask in [Discussions](https://github.com/gasparoff/rays/discussions) or open an
[issue](https://github.com/gasparoff/rays/issues/new/choose).
