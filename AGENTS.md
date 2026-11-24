# Notes for AI coding agents

Humans: read [CONTRIBUTING.md](CONTRIBUTING.md). This file is the same rules, condensed for
coding agents (Claude Code, Codex, Copilot…) working in this repository.

## Build and test

```sh
make bootstrap   # once: Ableton Link submodule + Beat Link helper
make test        # must pass before every commit
make lint        # swift-format, on files you touched
```

The library modules build and test without hardware. Only `Scripts/build-app.sh` needs the Beat Link helper.

## Layout

| Path | Rule |
|---|---|
| `Sources/RaysOutput`, `Sources/RaysTempo` | Foundation only. No imports of other RAYS modules. |
| `Sources/RaysCore` | Foundation + RaysOutput. Pure, deterministic, fully unit-tested. |
| `Sources/RaysControl`, `Sources/RaysEngine` | No SwiftUI/AppKit/CoreMIDI. |
| `Sources/RaysApp` | The only place for SwiftUI, AppKit, CoreMIDI, Network UI. |
| `Profiles/*.json`, `Controllers/*.json` | Data only. Validated by `CommunityProfilesTests` / `CommunityControllersTests`. |
| `Vendor/link` | Ableton Link submodule. Never edit. |

## Hard rules

- No behavior change without a test in `Tests/`.
- Saved user files (patch, scenes, MIDI map, preferences) must keep decoding: add a compatibility test with an old JSON sample when you touch a `Codable` type.
- Never enable fixture strobe, macro, program or sound-to-light channels by default. Blackout always wins.
- The 30 Hz engine path must not block, allocate needlessly or touch UI.
- Library modules build with strict concurrency; CI fails on any warning from them. No blanket `@unchecked Sendable` or `nonisolated(unsafe)`: document the owning queue or lock.
- English for identifiers, comments, docs. User-facing strings are localizable.
- Never commit build products, `Research/`, `Vendor/BeatLinkHelper/`, manuals or third-party images.
- New third-party code or data: add it to `THIRD_PARTY_NOTICES.md` with its license.
