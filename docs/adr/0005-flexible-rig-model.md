# 0005. A rig of N groups with variable segment counts

**Status:** Proposed, 2026-11-23

## Context
RAYS was built around one reference rig (two TRI 180 on the sides, one TRI 380 in the centre), and that
shape is hard-wired through the core:

- `FixtureRole` (`RaysCore/Fixtures.swift`) is a closed enum `left, center, right`. `Patch.roles(library:)`
  guesses a role when the patch has none: 6+ RGB segments means centre, otherwise by position.
- `RigFrame` (`RaysCore/Choreography.swift`) has three stored `RoleFrame`s, with
  `centerSegments = 6` and `centerCOBs = 3`; sides are always 1 RGB + 1 COB. Every choreography in
  `Choreography` writes those three fields directly.
- `SceneLook` orders emitters left to right with static tables (`rgbX`, `cobX`) that name `.left`,
  six centre segments and `.right`. `TrackTarget` (`SceneProgram.swift`) stores `left/center/right`
  booleans plus `segments` (6) and `cobs` (3) that only apply to the centre.
- `CustomScene` stores `leftLevel/centerLevel/rightLevel`; `ShowSettings` stores `levelLeft/Center/Right`;
  `MIDIMapping` routes `.level(FixtureRole, Double)`; `FixtureVisual.role` sorts the preview.
- `LightEngine` keeps a "shadow" rig built from `VarytecRig.referenceRig()` and draws its fixtures as
  `.previewOnly` for every role the real patch does not fill, so the preview always shows three lights.
- `StageLayout` (`StageGeometry.swift`) draws triangular mirrors with six zones and 1 or 3 COB strips,
  sized by `isLarge(profileID:)` (a `tri380` substring check).

A new JSON profile (ADR 0003) therefore works only if it can pose as one of three roles. Two PARs and a bar
on the left all receive the same `left` frame; a 12-zone bar in the centre gets 6 zones repeated by
`FixtureLevels.resampled`; a fourth position cannot exist. The data says "any fixture", the model says
"this rig".

## Decision
Replace the three fixed roles with an ordered list of **groups**. A group is a named position on the stage
with its own segment and COB counts. Choreographies render into a frame of groups; the composer keeps
mapping a group's frame onto each fixture's profile with the existing resampling.

### Data model (RaysCore)
```swift
public struct RigGroupID: Hashable, Codable, Sendable { public var rawValue: String }  // "left", "g-3F2A…"
public struct RigGroup: Codable, Equatable, Sendable {
    public var id: RigGroupID
    public var name: String          // user-facing, editable
    public var x: Double             // stage position 0 (left) … 1 (right), drives motion order
    public var rgbSegments: Int      // 1…64, defaults to the widest member profile
    public var cobs: Int             // 0…64
}
public struct RigLayout: Codable, Equatable, Sendable {
    public var groups: [RigGroup]   // ordered, 1…16
    public static let classic: RigLayout   // left (x 0, 1/1), center (x 0.5, 6/3), right (x 1, 1/1)
}
public struct RigFrame { public var groups: [RoleFrame] }   // indexed like RigLayout.groups
```
- `PatchedFixture` gains `group: RigGroupID?`; `Patch` gains `layout: RigLayout?` (nil = `.classic`).
- `FixtureRole` stays as a thin compatibility type: `RigGroupID.left/.center/.right` are the classic ids,
  and `RigFrame` keeps `left/center/right` as computed properties over the classic layout while callers move.
- `RigFrame` storage becomes `[RoleFrame]` sized once per layout change, so the 30 Hz path still writes into
  preallocated arrays and allocates nothing per frame.

### How scenes address groups
- The six built-in choreographies are written in **stage coordinates**, not roles: they already think in
  "edge", "centre", "left to right". Each emitter gets a normalised `(x, ring)` from its group's `x` and
  segment index (the `SceneLook.rgbX/cobX` tables become a function of the layout). A choreography that
  today special-cases the centre keeps doing so through "the group nearest x = 0.5" plus "the others".
- `TrackTarget` becomes a **selector**, not a set of booleans: `all`, `center` (group nearest 0.5),
  `sides` (all others), `left half`, `right half`, or an explicit list of group ids with optional
  per-group segment/COB masks. The existing presets (`.centerOnly`, `.sides`, `Preset.left/right`) map
  1:1 onto selectors, so the editor UI keeps its five buttons for the classic layout.
- Motion (`TrackMotion.chase`, `TrackDirection.forward/backward/center`) already ranks units by `x`; it
  works unchanged once units come from the layout instead of the static table.
- Per-group levels: `CustomScene` and `ShowSettings` store `levels: [RigGroupID: Double]`. MIDI
  `.level` actions take a group id; the classic three keep their existing faders.

### Saved-file compatibility
Every decoder keeps reading today's keys, as `TrackTarget` and `ShowSettings` already do with `decodeIfPresent`:

| File | Old field | New decoding |
|---|---|---|
| patch | `role: "left"` / missing | `group = "left"`; missing role keeps `Patch.roles` guessing, now returning classic ids |
| patch | no `layout` | `RigLayout.classic` |
| scenes | `leftLevel/centerLevel/rightLevel` | `levels["left"/"center"/"right"]` |
| scenes | `TrackTarget{left,center,right,segments,cobs}` | selector `groups([...])` with the centre mask on `"center"` |
| show.json | `levelLeft/Center/Right` | `levels[...]` |
| MIDI map | `.level(left)` | `.level(group "left")` |

Writers emit the new keys **and** the old ones while the layout is `.classic`, for one release, so a
downgrade still opens the files; the scenes envelope `version` is bumped only when a non-classic layout is
saved, and the existing "file comes from a newer version" path protects older builds. Each step adds a
`SceneBankCompatibilityTests`-style test with a JSON sample taken from the current release.

### Preview
- The shadow rig is derived from the layout, not from `VarytecRig.referenceRig()`: every group with no
  patched fixture gets one preview-only placeholder built from a generic profile with the group's segment
  and COB counts. A classic layout still shows the familiar three lights.
- `StageLayout` positions fixtures by group `x` and draws a mirror with `rgbSegments` zones (the facet
  angle already divides by a zone count; it becomes a parameter instead of 6). `isLarge(profileID:)`
  becomes "segment count above 1" so it no longer depends on a product name.
- ADR 0004 is unaffected: the preview still decodes the composed DMX bytes.

## Incremental plan
Each step is one small PR, green on its own, with no visible behaviour change until step 6.

1. **Golden frames.** Add a fingerprint test that renders every scene and bank on the classic rig at fixed
   beats and stores the hashes (extend `FingerprintRegressionTests`). Every later step must keep them.
2. **`RigLayout` and ids.** Add `RigGroupID`, `RigGroup`, `RigLayout.classic`, `Patch.layout` (optional)
   and `PatchedFixture.group` with decoding tests for old patches. Nothing reads them yet.
3. **`RigFrame` over an array.** Change storage to `[RoleFrame]` with `left/center/right` computed
   accessors and the `FixtureRole` subscript kept. Golden frames unchanged; allocation-free check on the
   30 Hz path.
4. **Layout-driven emitter table.** Generate `SceneLook.rgbX/cobX` from the layout; `TrackTarget` gains the
   selector with old-key decoding. Golden frames unchanged.
5. **Group levels.** `levels: [RigGroupID: Double]` in `CustomScene`, `ShowSettings` and MIDI routing, with
   dual-key writing and compatibility tests.
6. **Engine and preview.** `LightEngine` builds frames and the shadow rig from the patch layout;
   `StageLayout` takes segment counts and `x`. First user-visible change: a patch with an explicit layout.
7. **Setup UI.** Group editor in Setup (add, rename, reorder, assign fixtures), localized strings in
   `it.lproj`. Choreographies tuned for 1, 2, 4 and 5 groups with screenshot-free numeric tests
   (peaks, motion order, no strobe/program channel ever above 0).
8. **Cleanup.** Deprecate `FixtureRole` in public API once nothing in RaysCore uses it; stop writing the
   old keys after one release.

## Alternatives considered
- **Keep three roles, add more fixtures per role.** Already possible and cheap, but every fixture in a role
  shows the same frame: no chase across four PARs, no fourth position. Does not solve the problem.
- **Raise the constants** (`centerSegments = 12`, five roles). Every saved scene mask and choreography
  table changes size, old files need resizing anyway, and the next rig hits the new limit.
- **Per-fixture addressing** (each patched fixture is its own group). Simplest model, but scenes would
  depend on the exact patch: replacing one PAR with two breaks a saved scene. Groups keep scenes portable;
  a group with one fixture gives the same result when wanted.
- **Pixel-map / 2D canvas** (render an image, sample it per emitter). Most general and good for video-like
  looks, but it discards the beat-exact, testable choreography functions and the per-segment intent
  ("centre spokes", "U path"), and it costs more per frame. Could be added later as one more scene type
  on top of groups.

## Consequences
- RAYS works with any combination of profiles without pretending to be the reference rig; the classic
  layout keeps today's shows byte-identical.
- More surface to test: choreographies must be checked for several layouts, not one.
- Old files keep opening; files saved with a non-classic layout do not open in older versions (they are
  refused with the existing "newer version" message, never silently rewritten).
- The selector replaces booleans in `TrackTarget`, so the scene editor needs a group picker once more than
  three groups exist.
