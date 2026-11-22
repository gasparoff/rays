# 0002. Pro DJ Link through Beat Link in a separate helper process

**Status:** Accepted, 2026-11-22

## Context
Reading beats from Pioneer CDJ/XDJ consoles requires the Pro DJ Link protocol. The mature, battle-tested
implementation is Deep Symmetry's Beat Link (Java, EPL-2.0). Rewriting it in Swift would be large and fragile.

## Decision
RAYS runs a tiny headless Java adapter (`Sources/BeatLinkHelper`) on top of Beat Link as a child process.
It prints beat events as JSON lines on stdout; the app parses them (`BeatLinkEvent`) and feeds the Link timeline.
The helper's runtime is not committed; `Scripts/bootstrap.sh` prepares it.

## Consequences
- License boundary is clean: separate program, separate license.
- A helper crash never takes down the lighting engine; the app restarts it.
- Building the app needs a Beat Link Trigger installation (documented). Tests do not.
