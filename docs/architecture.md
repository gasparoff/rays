# Architecture

## Data flow

```
Tempo sources                Engine (30 Hz, serial queue)              Outputs
─────────────                ────────────────────────────              ───────
Ableton Link ──┐
Pro DJ Link ───┼─► Tempo ─► SceneSequencer ─► Choreography/SceneProgram ─► DMXComposer ─► OutputDriver (Art-Net) ─► node
Internal clock ┘                 ▲                                         │
MIDI controllers ─► MIDIRouter ──┘                                         └─► LatestMailbox ─► Stage preview
```

- **One source of truth for light.** The preview decodes the same composed DMX universes that
  are sent on the wire, so what you see is what the fixtures receive.
- **Engine never blocks.** UI receives only the latest frame (`LatestMailbox`); network and MIDI
  run on their own queues.
- **Data is plain JSON** in `~/Library/Application Support/Light System/`, written atomically.

## Modules

Lower layers never import higher ones. Everything except `RaysApp` and `LinkBridge` is
Foundation-only and runs in `swift test` without hardware.

```
RaysOutput   RaysTempo        leaves
    ▲            │
RaysCore         │            uses RaysOutput addresses (PortAddress, ArtNet.dmxSlots)
    ▲            │
RaysControl      │
    ▲            ▼
RaysEngine ◄─────┘            engine + config (Preferences embeds the MIDI map)
    ▲
RaysApp  ◄── LinkBridge       SwiftUI app, executable "LightSystem"
```

| Target | Depends on | Responsibility |
|---|---|---|
| `RaysOutput` | Foundation | Art-Net packets, `ArtNetController`, sACN, DMX USB Pro + serial port, `NodeRegistry`, UDP transport, direct-cable policy, `OutputActivity`, `LatestMailbox`, `OutputDriver` + registry |
| `RaysTempo` | Foundation | `TempoSource`, `TempoSnapshot`, internal clock, downbeat alignment, tap tempo, Pro DJ Link beat types, MIDI Clock, `TempoSourceRegistry` |
| `RaysCore` | RaysOutput | Fixtures, patch, profiles, Varytec rig, scenes, choreography, scene programs and editing, custom scenes, sequencer, DMX composer, stage geometry |
| `RaysControl` | RaysCore | MIDI decoder, `ControlAction`, `MIDIRouter` (Learn, soft takeover, relative encoders), `XoneK2`, LED feedback, `ControllerProfile` |
| `RaysEngine` | all of the above | `LightEngine` (30 Hz), `ConfigStore`, `Preferences`, `ShowSettings` |
| `LinkBridge` | Ableton Link SDK | C API over Link's C++ session state |
| `RaysApp` | everything, SwiftUI/AppKit/CoreMIDI | The macOS app: `Stage/`, `Editor/`, `Setup/`, `Live/`, `Services/`, `Theme/` |
| `BeatLinkHelper` | Beat Link (Java) | Child process that prints Pro DJ Link beats as JSON lines |

Cross-module helpers that are not public API use Swift's `package` access level.

## Extension points

| Extend | Where | Format |
|---|---|---|
| Fixtures | `Profiles/*.json` | `FixtureProfile` JSON, no code ([guide](adding-a-fixture.md)) |
| Controllers | `Controllers/*.json` | `ControllerProfile` JSON ([guide](adding-a-controller.md)) |
| Outputs | `OutputDriver` in `RaysOutput` | Swift: conform, then `OutputDriverRegistry.register` |
| Tempo | `TempoSource` in `RaysTempo` | Swift: conform, then `TempoSourceRegistry.register` |
| Scenes | `SceneProgram` / `CustomScene` | JSON, editable in-app |

### Output drivers

`OutputDriver` is the surface `LightEngine` uses: open/close, discovery (`pollIfDue`, `nodes`),
target selection (`preferredIdentity`, `manualIP`), `sendDMX` per universe and status strings
for Setup. Drivers: `ArtNetController` (default), `SACNDriver` (E1.31 multicast/unicast) and
`DMXUSBProDriver` (ENTTEC DMX USB Pro protocol over a POSIX serial port). `LightEngine(…,
outputDrivers:, outputDriverID:)` builds its driver from a registry; unknown ids fall back to
Art-Net. `useOutputDriver(_:registry:)` swaps it at runtime after disarming output.
`OutputSettings` (in `Preferences`) stores the choice and each driver's settings and builds the
registry. Drivers are only ever called from the engine's serial queue.

### Tempo sources

`TempoSource` is `capture()` + `setTempo` + `setStartStopSync`. `TempoSourceRegistry.builtIn`
holds the internal clock; the app registers Ableton Link (`LinkTempoSource`, which needs
`LinkBridge`). Pro DJ Link and MIDI Clock are deliberately not separate grids: their beats are
fed into the Link timeline (`followBeat`) so the lights, Ableton Live and other Link peers share
one grid. `MIDIClockParser` / `MIDIClockTempoSource` (RaysTempo) decode 24 ppqn clock; the app's
`MIDIClockListener` runs only when the beat source is MIDI Clock.

### Controllers

Layouts are data: `Controllers/*.json` is bundled into `Resources/Controllers`, and
`Application Support/Light System/Controllers/*.json` is loaded on top (same id = user file wins).
Invalid files appear in Setup like invalid fixture profiles.

`MIDIService` connects K2 inputs (built-in `XoneK2` profiles), inputs whose name matches a loaded
layout, and, only when the user enables Learn from all inputs, every other input. Each CoreMIDI
connection carries a tag, so `MIDIRouter.handle(_:fromK2:profile:)` gets the layout of the port
a message came from. LED feedback (`K2Feedback.leds(map:profile:state:)`) uses the same colour
rules for every layout. The K2 layouts stay built into Swift so the app works without any
resource files; `Controllers/xone-k2-*.json` are tested to match them.

## Roadmap

Contributions welcome on any of these. Open an issue to coordinate before large work.

- [ ] English UI and String Catalog localization (it, en, then community languages)
- [x] `ControllerProfile` JSON format and loader, Xone:K2 layouts as data
- [x] Route non-K2 controllers from their `ControllerProfile` (MIDI ports, LED feedback, on-screen guide)
- [x] `OutputDriver` protocol and registry (Art-Net)
- [x] More drivers: sACN (E1.31), ENTTEC DMX USB Pro, driver choice in Setup
- [ ] sACN universe discovery and synchronization; DMX USB Pro Mk2 second universe
- [x] `TempoSource` registry (internal clock, Ableton Link)
- [x] MIDI Clock beat source
- [ ] Audio onset as fallback
- [ ] Scene sharing: export/import a `.rays-scene` file, community scene gallery
- [ ] Larger rigs: more than three positions, multiple universes, pixel bars
- [ ] Signed and notarized releases, Homebrew cask
