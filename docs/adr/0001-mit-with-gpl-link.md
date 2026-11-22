# 0001. RAYS code is MIT; binaries with Ableton Link are GPLv2+

**Status:** Accepted, 2026-11-22

## Context
RAYS wants the widest possible community: permissive licensing invites forks, embedding and contributions.
Tight tempo sync needs Ableton Link, whose SDK is GPLv2+ (or a commercial license from Ableton).

## Decision
All RAYS source code is MIT. Link is a git submodule, never copied into the tree. Distributed `RAYS.app`
binaries statically include Link and are therefore a combined work under GPLv2+, which MIT permits.
The build ships all license texts in `Contents/Resources/Licenses`.

## Consequences
- Anyone may reuse RAYS code under MIT, including closed-source, as long as they don't ship Link without a commercial license.
- Official releases must always point to the corresponding public source.
- A future build flag to compile without Link would give a fully MIT binary.
