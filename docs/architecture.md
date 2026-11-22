# Architecture

## Data flow

```
Tempo sources                Engine (30 Hz, serial queue)              Outputs
─────────────                ────────────────────────────              ───────
Ableton Link ──┐
Pro DJ Link ───┼─► Tempo ─► SceneSequencer ─► Choreography/SceneProgram ─► DMXComposer ─► ArtNetController ─► node
Internal clock ┘                 ▲                                         │
MIDI (K2, Learn) ─► MIDIRouter ──┘                                         └─► LatestMailbox ─► Stage preview
```

- **One source of truth for light.** The preview decodes the same composed DMX universes that
  are sent on the wire, so what you see is what the fixtures receive.
- **Engine never blocks.** UI receives only the latest frame (`LatestMailbox`); network and MIDI
  run on their own queues.
- **Data is plain JSON** in `~/Library/Application Support/Light System/`, written atomically.

## Modules

| Target | Depends on | Responsibility |
|---|---|---|
| `LightCore` | Foundation | Art-Net, discovery, fixtures/patch, scenes, choreography, sequencer, MIDI routing, config store |
| `LinkBridge` | Ableton Link SDK | C API over Link's C++ session state |
| `LightSystem` | LightCore, LinkBridge, SwiftUI/AppKit/CoreMIDI | The macOS app |
| `BeatLinkHelper` | Beat Link (Java) | Child process that prints Pro DJ Link beats as JSON lines |

## Extension points

| Extend | Where | Format |
|---|---|---|
| Fixtures | `Profiles/*.json` | `FixtureProfile` JSON, no code |
| Controllers | `MIDIMapping.swift` (`XoneK2` pattern) | Swift today, JSON planned |
| Scenes | `SceneProgram` / `CustomScene` | JSON, editable in-app |

## Roadmap

Contributions welcome on any of these. Open an issue to coordinate before large work.

- [ ] English UI and String Catalog localization (it, en, then community languages)
- [ ] `ControllerProfile` JSON: MIDI layouts without Swift (Launchpad, APC, Launch Control, DDJ)
- [ ] `OutputDriver` protocol: sACN (E1.31), ENTTEC DMX USB Pro, more Art-Net nodes
- [ ] `TempoSource` protocol: MIDI clock, audio onset as fallback
- [ ] Scene sharing: export/import a `.rays-scene` file, community scene gallery
- [ ] Larger rigs: more than three positions, multiple universes, pixel bars
- [ ] Signed and notarized releases, Homebrew cask
