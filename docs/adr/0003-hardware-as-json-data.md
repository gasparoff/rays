# 0003. Fixtures and controllers are JSON data, not code

**Status:** Accepted, 2026-11-22

## Context
The value of a lighting tool grows with the hardware it supports, and most people who own a light or a
controller are not Swift developers.

## Decision
Fixture profiles (`Profiles/*.json`, `FixtureProfile`) and controller layouts (`Controllers/*.json`,
`ControllerProfile`) are plain JSON, bundled into the app and also loaded from the user's
Application Support folder. Test suites validate every file in the repository.

## Consequences
- A first contribution is one JSON file and one PR, checked by CI before review.
- The engine only understands a small, safe set of channel kinds; fixture features RAYS cannot drive are mapped to `ignore`.
- Profiles not tested on real hardware are marked `isVerified: false` and shown as such.
