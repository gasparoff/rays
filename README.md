<p align="center">
  <img src="Assets/RAYS-wordmark-white.svg" alt="RAYS" width="280">
</p>

<p align="center">
  <b>Beat-synced DMX lighting for DJs. Native on macOS, open to every light and controller.</b><br>
  Art-Net · Ableton Link · Pro DJ Link · MIDI controllers
</p>

<p align="center">
  <a href="https://github.com/gasparoff/rays/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/gasparoff/rays/actions/workflows/ci.yml/badge.svg"></a>
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-blue.svg"></a>
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-black">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-orange">
  <a href="CONTRIBUTING.md"><img alt="PRs welcome" src="https://img.shields.io/badge/PRs-welcome-brightgreen"></a>
</p>

<!-- Hero GIF (stage preview following the beat) will go at docs/images/hero.gif -->

RAYS turns a Mac into a lighting console that **follows the music by itself**. It locks to
the tempo of your DJ console or any Ableton Link app, and plays original choreographies on
real DMX fixtures through an Art-Net node. No lighting desk, no timeline programming, no
subscription.

> 🇮🇹 L'interfaccia è oggi in italiano. Manuale completo in italiano: [docs/manuale-it.md](docs/manuale-it.md).

## Why RAYS

- **Locks to the beat, not to a microphone.** Tempo and phase come from Ableton Link or straight
  from Pioneer CDJ/XDJ consoles over Pro DJ Link. Scenes land on the downbeat.
- **Choreographies, not chases.** Twelve built-in scenes in two banks (House, Club 130–138), plus
  your own, edited on a shared rhythm grid with per-track step, cycle, envelopes and timing.
- **Live preview that tells the truth.** The stage view decodes the very same DMX bytes that go
  out on the wire.
- **Hands on.** Full Allen & Heath Xone:K2 layout with LED feedback, MIDI Learn for anything else,
  Build → Drop gesture, Flash, Blackout.
- **Made for real gigs.** Auto-discovery of Art-Net nodes and consoles, automatic reconnection,
  safe blackout, no App Nap while lights are on.
- **Hackable.** Foundation-only core modules with ~200 unit tests, and fixtures and controller
  layouts described in plain JSON.

## Quick start

Requirements: macOS 14+, Xcode 16 / Swift 6, an Art-Net node (tested: ENTTEC ODE MK3).

```sh
git clone --recursive https://github.com/gasparoff/rays.git
cd rays
Scripts/bootstrap.sh     # fetches Ableton Link (submodule) and the Beat Link helper
swift test               # run the core test suite
Scripts/build-app.sh     # builds dist/RAYS.app
open dist/RAYS.app
```

No hardware yet? Launch the app anyway: the stage preview runs without any light connected.

## Supported hardware

| Type | Supported | Status |
|---|---|---|
| Art-Net nodes | ENTTEC ODE MK3 | ✅ tested on hardware |
| Art-Net nodes | Any Art-Net 4 node | 🟡 should work, [report it](../../issues/new?template=hardware-report.yml) |
| sACN (E1.31) | Any E1.31 receiver, multicast or unicast | 🟡 implemented from the spec, not yet tested on hardware |
| USB DMX | ENTTEC DMX USB Pro and compatible (DMXking ultraDMX Pro/Micro) | 🟡 implemented from the protocol, not yet tested on hardware |
| Fixtures | Varytec Retro Blinder TRI 180 (5/8 ch), TRI 380 (5/25 ch) | ✅ verified profiles |
| Fixtures | Generic RGB, RGBW, Dimmer+RGB, Dimmer+RGBW | ✅ built in |
| Fixtures | Varytec Event Par IP65 4in1 (4/7/9 ch), LED Pad 7 RGBWA (5/6/9 ch), LED Pad 7 RGBWAUV (6/7/10 ch) | 🟡 from the official manuals, not yet tested on hardware |
| Fixtures | Generic RGBA, RGBWA, RGBWA+UV PARs, 2-zone RGB bar | 🟡 generic profiles in `Profiles/` |
| Fixtures | ~110 PARs, bars and washes from 12 brands (Chauvet DJ, ADJ, Cameo, Eurolite, Stairville, Showtec, BeamZ, Martin, Elation…) | 🟡 converted from the [Open Fixture Library](https://open-fixture-library.org), not yet tested on hardware |
| Controllers | Allen & Heath Xone:K2 (Classic and Live v2 layouts) | ✅ |
| Controllers | Akai APC40 mkII | 🟡 layout from Akai's published protocol, not yet tested on hardware |
| Controllers | Any controller with a layout in `Controllers/` | 🟡 routed from JSON, LED feedback if described |
| Controllers | Any MIDI controller | ✅ via MIDI Learn |
| Tempo | Ableton Link, Pioneer Pro DJ Link (CDJ/XDJ) | ✅ |
| Tempo | MIDI Clock (opt-in) | 🟡 not yet tested on hardware |

Full matrix, including what is not supported and why: [docs/hardware.md](docs/hardware.md).

**Your light or controller is missing?** Adding it takes one JSON file and no Swift:
see [Add a fixture](docs/adding-a-fixture.md) and [Add a controller](docs/adding-a-controller.md).
Every new profile is a welcome first PR.

UV channels are kept at 0 for now (RAYS has no UV colour yet), like strobe, programme and sound
channels.

## How it works

```
 Pro DJ Link ─┐                                 ┌─► Stage preview (SwiftUI/AppKit)
 Ableton Link ┼─► Tempo ─► Scene sequencer ─► DMX composer ─┤
 MIDI (K2)  ──┘           (choreographies)    (patch+profiles) └─► Art-Net ─► node ─► lights
```

| Module | What lives there |
|---|---|
| `Sources/RaysOutput` | Art-Net packets, node discovery, UDP transport, the `OutputDriver` protocol and registry. |
| `Sources/RaysTempo` | Tempo snapshots, internal clock, tap tempo, Pro DJ Link beats, the `TempoSource` registry. |
| `Sources/RaysCore` | Fixtures, patch, profiles, scenes, choreography, scene programs, sequencer, DMX composer, stage geometry. |
| `Sources/RaysControl` | MIDI decoding, `ControlAction`s, the router (Learn, soft takeover), Xone:K2 layouts, `ControllerProfile` JSON. |
| `Sources/RaysEngine` | The 30 Hz `LightEngine` and the JSON config store. |
| `Sources/RaysApp` | The macOS app (`Stage/`, `Editor/`, `Setup/`, `Live/`, `Services/`, `Theme/`); builds the `LightSystem` executable. |
| `Sources/LinkBridge` | Thin C bridge over the official Ableton Link C++ SDK. |
| `Sources/BeatLinkHelper` | Headless Java adapter over Beat Link, run as a child process. |
| `Profiles/` | Community fixture profiles (JSON), bundled into the app. |
| `Controllers/` | Controller layouts (JSON), bundled into the app. |

More in [docs/architecture.md](docs/architecture.md).

## Contributing

RAYS grows with the people who use it on stage. The easiest ways in:

1. **Add a fixture profile** for a light you own ([guide](docs/adding-a-fixture.md)).
2. **Add a controller layout** ([guide](docs/adding-a-controller.md)).
3. **Share a scene idea** in [Discussions](../../discussions).
4. **Translate the UI** (English first!).

Read [CONTRIBUTING.md](CONTRIBUTING.md) and look for
[`good first issue`](../../issues?q=is%3Aopen+label%3A%22good+first+issue%22).

## Safety

RAYS can drive strobes and high-power blinders. Built-in scenes never trigger fixtures'
internal strobe programs, and Esc always means blackout. Respect photosensitivity
guidelines when you design your own scenes.

## Author

RAYS is created and maintained by **Manuel Gasparini** ([@gasparoff](https://github.com/gasparoff)),
born from real club nights and tested on real rigs. If RAYS lights up your set, a ⭐ helps others find it.

## License

RAYS source code is [MIT](LICENSE). Built apps include Ableton Link (GPLv2+) and run
Beat Link (EPL-2.0) as a helper: see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
RAYS is not affiliated with Ableton, Pioneer DJ, ENTTEC, Varytec or Allen & Heath.
