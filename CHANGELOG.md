# Changelog

All notable changes to RAYS are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the
project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- First open-source release under the MIT license.
- Output drivers: Art-Net (default), sACN / E1.31, ENTTEC DMX USB Pro and compatibles. Chosen in Setup.
- MIDI Clock as a beat source, next to Ableton Link and Pro DJ Link.
- Controller layouts as JSON (`Controllers/`): any described MIDI controller gets bindings, LED feedback and an on-screen guide.
- Community fixture profiles as JSON (`Profiles/`), with automatic validation in the test suite.
- Varytec Event Par, LED Pad 7 RGBWA / RGBWAUV profiles and generic RGBA/RGBWA/UV profiles.
- English user interface, with Italian as the first translation (`Localization/`). Profile names and notes stay as published by the manufacturer.
- Contributor docs, issue and PR templates, CI on macOS.
- Release workflow: pushing a `v*` tag publishes `RAYS.app` (Apple silicon) on GitHub Releases; CI also builds the app for every change.
- Live window layout: press Layout to reorder, resize and hide panels on a 12-column grid, or pick a preset (Classic, Tempo on the right, Big stage, Minimal). The layout is saved; the performance panel can't be hidden.
- Blackout always in the top bar, with a red frame around the window while it is on.
- Command search (⌘K): type a few letters of a scene or an action (blackout, lights, banks, layouts, Setup) and press Return.

### Changed
- Core split into `RaysOutput`, `RaysTempo`, `RaysCore`, `RaysControl`, `RaysEngine` modules; the app lives in `Sources/RaysApp`.
- `Scripts/build-app.sh` builds without the Beat Link helper (Pro DJ Link then unavailable) instead of failing; the bundled license notice now covers public distribution.
- Bundle identifier is now `io.github.gasparoff.rays`. Saved patches and scenes are kept; the remembered scene bank and internal BPM reset once.

### Fixed
- A light test (Setup → Lights) no longer clears an active blackout or arms the output during blackout; the test buttons are disabled while blacked out.
- DMX USB Pro writes are bounded (20 ms per frame): a stalled widget can no longer hold the engine queue and delay blackout or shutdown.

### Security
- The Art-Net node list is capped at 64 entries, so a flood of fake ArtPollReply packets can't grow memory; fresh and selected nodes are never evicted.
- The adapter name in the administrator command for the direct cable is checked byte by byte (a trailing newline used to pass the old pattern).
- Release builds launch the Beat Link helper only from their own bundle.
- GitHub Actions are pinned to commit SHAs (Dependabot keeps them current) and checkouts don't keep the token.
- `SECURITY.md` explains scope and how to verify a release; `docs/security.md` describes the security model.

## [1.5.5] - 2026-10-31

Last private build before open-sourcing: House and Club 130–138 scene banks, full-screen scene editor
with shared rhythm grid, Xone:K2 Classic and Live v2 layouts, auto-reconnect, display-sleep protection.
