# Security model

RAYS controls lights on a local network. It does not talk to the Internet: no telemetry, no
update checks, no accounts. This page lists what RAYS trusts, what it doesn't, and the code
that enforces each boundary. To report a problem, see [SECURITY.md](../SECURITY.md).

## Network input

RAYS treats every packet as hostile. Lighting protocols carry no authentication, so the
defence is careful parsing and bounded state, not trust in the sender.

- **Art-Net discovery** (`RaysOutput/ArtNet.swift`, `NodeRegistry.swift`). `ArtPollReply.parse`
  checks the header, OpCode and minimum length before reading any field, and every string
  is read from a fixed slice. The node registry holds at most 64 nodes: a flood of fake
  replies cannot grow memory, and it never evicts a node that is still answering or the
  node the user selected. A generic Art-Net node is never selected automatically.
- **sACN and DMX USB Pro** only send. Their sockets and serial ports ignore incoming data.
- **Pro DJ Link** runs in a separate process, the Beat Link helper. The app reads only lines
  that start with `LSBLT `, at most 16 KB each, in a buffer capped at 128 KB, decodes them
  with `JSONDecoder` and accepts a beat only from deck 1–4, at 20–400 BPM, timestamped in
  the last half second (`RaysTempo/BeatLinkEvent.swift`). The helper never takes tempo master,
  sends playback commands or downloads metadata.
- **Ableton Link** is the official SDK (`Vendor/link`, a git submodule pinned to a commit).

## Files

- **Fixture profiles and controller layouts** are data only. They are decoded with
  `JSONDecoder` into fixed types, so a file can describe channels but never run code.
  `Patch.validate` and `DMXComposer` refuse a fixture whose footprint leaves the 512-slot
  universe; segments are clamped to 0–63; MIDI channels and notes are clamped to their
  ranges. There is no channel kind for strobe, macro or program channels: profiles map them
  to `ignore`, which is always 0, and blackout zeroes every slot, constants included.
  `CommunityProfilesTests` and `CommunityControllersTests` validate every file in the
  repository on each pull request.
- **Saved files** live in `~/Library/Application Support/RAYS/` and are written
  atomically. A damaged file is reported in the app and falls back to defaults; it never
  crashes the app.

## Administrator rights

To use the direct cable to an ENTTEC ODE, RAYS can add one temporary IP alias to a wired
adapter. `DirectCablePolicy` builds the only two commands that ever run as root:

```
/sbin/ifconfig enN alias 192.168.0.20 netmask 255.255.255.0
/sbin/ifconfig enN inet 192.168.0.20 -alias
```

The interface name is checked byte by byte (`en` plus one to three ASCII digits), every other
token is a constant, and macOS shows its own password prompt each time. RAYS never changes
DHCP, DNS, routes or Wi-Fi, and refuses when the alias would overlap another network.

## Helper process

Release builds launch the Beat Link helper only from inside their own app bundle. Debug
builds also look in `Vendor/BeatLinkHelper` of the source checkout.

## Build and release

- CI runs on `pull_request`, never `pull_request_target`, with a read-only token, so code from
  a fork can't reach secrets or write to the repository.
- Every GitHub Action is pinned to a commit SHA, and checkouts don't keep the token
  (`persist-credentials: false`). Dependabot keeps the actions and the Ableton Link
  submodule up to date.
- The release workflow pins the Beat Link Trigger version and checks the SHA-256 of its DMG
  before using it, and publishes a build provenance attestation for the zip.
- Release builds are not yet signed with a Developer ID or notarized by Apple. Until they
  are, check the SHA-256 and the attestation as shown in [SECURITY.md](../SECURITY.md).
