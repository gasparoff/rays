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
- Contributor docs, issue and PR templates, CI on macOS.

### Changed
- Core split into `RaysOutput`, `RaysTempo`, `RaysCore`, `RaysControl`, `RaysEngine` modules; the app lives in `Sources/RaysApp`.
- Bundle identifier is now `io.github.gasparoff.rays`. Saved patches and scenes are kept; the remembered scene bank and internal BPM reset once.

## [1.5.5] - 2026-10-31

Last private build before open-sourcing: House and Club 130–138 scene banks, full-screen scene editor
with shared rhythm grid, Xone:K2 Classic and Live v2 layouts, auto-reconnect, display-sleep protection.
