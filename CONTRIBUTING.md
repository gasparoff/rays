# Contributing to RAYS

Thanks for helping RAYS light up more stages. Contributions of every size are welcome:
a fixture profile, a controller layout, a translation, a bug report, a scene idea.

## Ways to contribute

| You want to… | Do this | Swift needed? |
|---|---|---|
| Add a light you own | [docs/adding-a-fixture.md](docs/adding-a-fixture.md) | No, one JSON file |
| Add a MIDI controller | [docs/adding-a-controller.md](docs/adding-a-controller.md) | A little |
| Propose a scene or feature | Open an [idea](../../issues/new?template=idea.yml) or a Discussion | No |
| Report hardware that works | [Hardware report](../../issues/new?template=hardware-report.yml) | No |
| Fix a bug / build a feature | Pick an issue, comment that you're on it, open a PR | Yes |

## Development setup

```sh
git clone --recursive https://github.com/gasparoff/rays.git
cd rays
make bootstrap   # Ableton Link submodule + Beat Link helper
make test
make build       # dist/RAYS.app
```

`make help` lists every task (`lint`, `format`, `clean`). Big design choices are recorded in
[docs/adr](docs/adr/README.md): read them before proposing to change one.

Requirements: macOS 14+, Xcode 16 or a Swift 6 toolchain.
You don't need any lighting hardware to work on most of the code: the `Rays*` library modules are
Foundation-only and fully covered by unit tests, and the app's stage preview works offline.

## Ground rules for code

- **Keep the library modules Foundation-only.** No SwiftUI, AppKit or CoreMIDI in `RaysOutput`,
  `RaysTempo`, `RaysCore`, `RaysControl` or `RaysEngine`. Anything that can be tested without
  hardware belongs there, not in `RaysApp`. Lower layers never import higher ones (see
  [architecture](docs/architecture.md#modules)).
- **Formatting:** `.swift-format` describes the house style. Run
  `swift format lint --configuration .swift-format <files you touched>`; don't reformat files you
  didn't change.
- **Every behavior change comes with a test** in `Tests/RaysTests`.
- **Never break saved user data.** Scene, patch and MIDI files in
  `~/Library/Application Support/Light System/` must keep loading. If you change a `Codable`
  type, add a compatibility test with an old JSON sample.
- **Safety first.** Never enable fixtures' internal strobe/macro channels by default. Blackout
  must always win. Output must never turn on as a side effect of editing.
- **Realtime path stays lean.** The engine runs at 30 Hz on a serial queue: no allocations in
  hot loops you can avoid, no blocking I/O, no UI work.
- Follow the existing style (Swift API Design Guidelines, 4-space indent). Code identifiers
  and comments in English. User-facing strings go through localization.

## Pull requests

1. Fork, create a branch (`fixture/varytec-pad7`, `fix/k2-led-feedback`, …).
2. Keep the PR focused on one thing. Small PRs get merged fast.
3. Make sure `swift test` passes locally. CI runs the same.
4. Add a line under *Unreleased* in [CHANGELOG.md](CHANGELOG.md).
5. Fill in the PR template, including how you tested (hardware or not).

By contributing you agree that your contribution is licensed under the MIT License.

## Code of Conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md). Be kind; we're all here
for the music.
