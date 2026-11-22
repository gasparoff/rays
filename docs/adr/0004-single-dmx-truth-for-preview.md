# 0004. The stage preview decodes the same DMX bytes sent to the wire

**Status:** Accepted, 2026-11-22

## Context
On stage, a preview that disagrees with the lights is worse than no preview.

## Decision
The engine composes DMX universes once per 30 Hz frame. Output drivers send those bytes; the preview
receives the same frame through `LatestMailbox` and decodes colors from it using the patch and profiles.

## Consequences
- Patch or profile mistakes are visible in the preview before the show.
- The preview is a model of emitters, not a photometric simulation.
- UI can drop frames without ever slowing the engine.
