# Architecture

## Data flow

```
Tempo sources                Engine (30 Hz, serial queue)              Outputs
─────────────                ────────────────────────────              ───────
Ableton Link ──┐
Pro DJ Link ───┼─► Tempo ─► SceneSequencer ─► Choreography/SceneProgram ─► DMXComposer ─► OutputDriver (Art-Net) ─► node
Internal clock ┘                 ▲                                         │
MIDI (K2, Learn) ─► MIDIRouter ──┘                                         └─► LatestMailbox ─► Stage preview
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
| `RaysOutput` | Foundation | Art-Net packets, `ArtNetController`, `NodeRegistry`, UDP transport, direct-cable policy, `OutputActivity`, `LatestMailbox`, `OutputDriver` + registry |
| `RaysTempo` | Foundation | `TempoSource`, `TempoSnapshot`, internal clock, downbeat alignment, tap tempo, Pro DJ Link beat types, `TempoSourceRegistry` |
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
for Setup. `ArtNetController` is the first driver. `LightEngine(…, outputDrivers:, outputDriverID:)`
builds its driver from a registry; unknown ids fall back to Art-Net. Drivers are only ever called
from the engine's serial queue.

### Tempo sources

`TempoSource` is `capture()` + `setTempo` + `setStartStopSync`. `TempoSourceRegistry.builtIn`
holds the internal clock; the app registers Ableton Link (`LinkTempoSource`, which needs
`LinkBridge`). Pro DJ Link is deliberately not a separate source: console beats are fed into the
Link timeline so the lights, Ableton Live and other Link peers share one grid.

### Controllers

Layouts are data: `Controllers/*.json` is bundled into `Resources/Controllers`, and
`Application Support/Light System/Controllers/*.json` is loaded on top (same id = user file wins).
Invalid files appear in Setup like invalid fixture profiles. The Xone:K2 files are tested to be
identical to the built-in `XoneK2` presets, which still drive the K2.

## Roadmap

Contributions welcome on any of these. Open an issue to coordinate before large work.

- [ ] English UI and String Catalog localization (it, en, then community languages)
- [x] `ControllerProfile` JSON format and loader, Xone:K2 layouts as data
- [ ] Route non-K2 controllers from their `ControllerProfile` (MIDI ports, LED feedback, on-screen guide)
- [x] `OutputDriver` protocol and registry (Art-Net)
- [ ] More drivers: sACN (E1.31), ENTTEC DMX USB Pro, driver choice in Setup
- [x] `TempoSource` registry (internal clock, Ableton Link)
- [ ] More sources: MIDI clock, audio onset as fallback
- [ ] Scene sharing: export/import a `.rays-scene` file, community scene gallery
- [ ] Larger rigs: more than three positions, multiple universes, pixel bars
- [ ] Signed and notarized releases, Homebrew cask
