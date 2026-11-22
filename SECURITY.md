# Security policy

## Reporting a vulnerability

Please **do not open a public issue, discussion or pull request** for a security problem.
Report it privately through
[GitHub private vulnerability reporting](https://github.com/gasparoff/rays/security/advisories/new).
Only the maintainer sees the report.

Please include what you found, how to reproduce it (a packet capture, a JSON file or a few
steps), and the RAYS version or commit. You'll get a first answer within a week. We agree a
fix and a disclosure date together; you are credited in the advisory unless you prefer not to be.

## Supported versions

Only the latest release and `main` receive security fixes.

## What is in scope

RAYS is a desktop app for a lighting rig on a local network. Reports are most useful when they
show that something crossing one of these boundaries can do more than it should:

| Input | Comes from | What RAYS must never do because of it |
|---|---|---|
| ArtPollReply packets (UDP 6454) | anyone on the LAN | crash, hang the 30 Hz engine, grow memory without bound |
| Pro DJ Link packets, via the Beat Link helper | anyone on the LAN | crash, or set the tempo from a stale or malformed beat |
| Ableton Link session | anyone on the LAN | crash or block the engine |
| MIDI and MIDI Clock | connected devices | crash, or enable strobe/macro channels |
| Fixture profiles and controller layouts (JSON) | community pull requests, files users copy in | crash, write outside the fixture's DMX footprint, override blackout |
| Saved files (patch, scenes, MIDI map, preferences) | the user's own disk | crash on a damaged file |
| The administrator prompt for the direct-cable IP alias | the app | run anything other than the one `ifconfig` alias command |
| Release builds | GitHub Actions | ship code that is not in this repository at the release tag |

See [docs/security.md](docs/security.md) for the threat model and the protections in place.

## What is not a vulnerability

Art-Net, sACN, Pro DJ Link and Ableton Link have no authentication by design: anyone on the
same network can send DMX to your lights or change the Link tempo. That is how every lighting
console works. Run the show on a network you control (a dedicated switch or the direct cable)
rather than on public Wi-Fi.

## Verifying a release

Every release zip comes with a `.sha256` file and a build provenance attestation from
GitHub Actions. To check that a zip was built by this repository's release workflow:

```sh
shasum -a 256 -c RAYS-<version>-macOS-arm64.zip.sha256
gh attestation verify RAYS-<version>-macOS-arm64.zip --repo gasparoff/rays
```
