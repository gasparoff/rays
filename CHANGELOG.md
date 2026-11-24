# Changelog

All notable changes to RAYS are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the
project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Performance faders follow the rig: one level fader per group of lights in the patch, named after the group, and Warm light only when a light has a white channel. The classic three-position rig keeps today's six faders.
- Customize faders: right-click the faders, or use the slider button in Layout mode, to hide faders or change their order. Master brightness always stays; hidden faders keep their level.
- Your own scene banks: the **+** beside the bank picker adds one that starts from the House or Club scenes; right-click it to rename or delete it. Keys 1–6, the Xone pads and the Build → Drop gesture play the bank you pick; each pad is edited, restored and copied like the built-in ones.
- Interface language in Setup › Advanced › Language: follow macOS, or pick English or Italian. It applies after a restart, with a Restart now button. New translations in `Localization/` appear there without code changes.

### Changed
- House pads now have the same scene model as Club pads: they open in the editor with their name and colors, and Restore original brings back both. An untouched House pad still plays exactly as before. Existing scenes and edits are kept; `custom-scenes.json` gains a `banks` key only once you add a bank.

### Fixed
- Section titles (Shortcuts, Tempo, Scenes…) are now translated like the rest of the interface.

## [0.2.0] - 2026-11-24

Signed and notarized app, composable Live window, user guide.

### Added
- User guide in English (`docs/manual.md`), from install to a show, linked from the README.
- Live window layout: press Layout to reorder, resize and hide panels on a 12-column grid, or pick a preset (Classic, Tempo on the right, Big stage, Minimal). The layout is saved; the performance panel can't be hidden.
- Blackout always in the top bar, with a red frame around the window while it is on.
- Command search (⌘K): type a few letters of a scene or an action (blackout, lights, banks, layouts, Setup) and press Return.
- Countdown ring on a queued scene button: it fills until the scene starts on its beat or downbeat.
- Click a light in the stage preview (Shift for more) to select it: a bar shows where it is patched and the brightness of its position.
- The stage preview draws every light as it looks, from its profile: PARs with their LED array, bars and pixel strips, LED panels, spots and moving heads on their yoke, blinder cells, besides the Varytec mirrors. Each zone and white emitter is coloured from the DMX values, in the order the profile declares.

### Changed
- Smaller, uniform corner radii across the app: one shared scale (10 points for panels, 6 for controls, 4 for chips) instead of values from 3 to 18 and pill shapes. Controls on the same row share one height: the top bar status boxes, Layout, Setup, search and Blackout are all 40 points high.
- Saved files now live in `~/Library/Application Support/RAYS`. An existing `Light System` folder is moved there on first launch and a link is left at the old path, so nothing is lost and older builds still find it.
- RAYS appears as "RAYS" on the Pro DJ Link network and in macOS MIDI, instead of the old project name.
- The app is signed with a Developer ID and notarized by Apple: it opens with a double click, no more Open Anyway ([docs/releasing.md](docs/releasing.md)).

### Fixed
- A damaged `midi.json` or `preferences.json` is copied aside and reported in Setup instead of being overwritten by the next save.
- Save errors are shown in the app instead of being ignored.
- DMX USB Pro output no longer blocks the 30 Hz engine while a frame is written.

## [0.1.0] - 2026-11-23

First public release.

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

## Before 0.1.0

Private builds were numbered 1.x; the public project restarted at 0.1.0. The last one (1.5.5,
2026-10-31) had: House and Club 130–138 scene banks, full-screen scene editor
with shared rhythm grid, Xone:K2 Classic and Live v2 layouts, auto-reconnect, display-sleep protection.

[Unreleased]: https://github.com/gasparoff/rays/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/gasparoff/rays/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/gasparoff/rays/releases/tag/v0.1.0
