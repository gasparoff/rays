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
public enum FixtureShape: String, Codable, Sendable { case triangle, bar, par, movingHead, generic }
public struct StagePoint: Codable, Equatable, Sendable { public var x: Double; public var y: Double }
public struct RigGroup: Codable, Equatable, Sendable {
    public var id: RigGroupID
    public var name: String          // user-given, editable
    public var labelColor: SceneRGB  // colour of the group's label and selection in the UI
    public var shape: FixtureShape   // every fixture in a group has the same shape kind
    public var position: StagePoint  // free 2D position on the stage canvas, x and y normalised 0…1
                                     // (x: left → right, y: back → front); set by dragging
    public var rotation: Double      // optional drawing hints, degrees / factor; never affect DMX
    public var scale: Double
    public var roles: Set<String>    // optional tags scenes can target ("center", "side", "accent")
    public var master: Double        // per-group intensity master 0…1, replaces the role faders
}
public struct RigLayout: Codable, Equatable, Sendable {
    public var groups: [RigGroup]           // any number of groups
    public static let classic: RigLayout    // preset: left (0, 0.5), center (0.5, 0.5), right (1, 0.5)
}
public struct RigFrame { public var groups: [GroupFrame] }  // indexed like RigLayout.groups
public struct GroupFrame { public var fixtures: [RoleFrame] } // one RoleFrame per fixture, sized by profile
```
- A group holds 1 to a few dozen fixtures (`PatchedFixture.group: RigGroupID?`). Segment and COB counts
  come from each fixture's profile, not from the group, so a 12-zone bar gets 12 zones and a PAR gets 1.
  An optional `PatchedFixture.offset: StagePoint` spreads fixtures inside their group on the canvas.
- `Patch` gains `layout: RigLayout?`; nil decodes as `.classic`. Today's three positions are just that
  layout preset (groups `left`, `center`, `right` with roles `side`/`center`/`side` and today's shapes),
  kept for saved patches and offered as a starting point. Positions are layout data only: moving a group
  never changes a DMX byte, only which emitter a spatial ordering reaches first.
- `FixtureRole` stays as a thin compatibility type mapping to the classic group ids; `RigFrame` keeps
  `left/center/right` computed accessors while callers migrate.
- `RigFrame` storage is sized once per layout change, so the 30 Hz path still writes into preallocated
  arrays and allocates nothing per frame.

### How scenes address groups
Scenes never name a physical position. A target is one of:
- **a role** (`center`, `side`, `all`, or any user tag): resolved against the groups carrying it;
- **a spatial ordering** computed from group positions: "left to right" (rank by x), "right to left",
  "back to front" (y), "from the centre out" (distance from the canvas centre), "bounce";
- **explicit groups** (ids picked on the canvas), with optional per-fixture segment/COB masks.

Each emitter gets a normalised stage point from its group position, fixture offset and segment index; the
`SceneLook.rgbX/cobX` tables become a function of the layout instead of static data. `TrackMotion.chase` and
`TrackDirection.forward/backward/center` already rank units by x, so they become spatial orderings
unchanged; a chase is always computed from each group's real x (and fixture offset), never from patch
order. The six built-in choreographies keep their intent ("centre spokes", "edges", "across the stage")
through roles plus orderings, which is why **existing scenes stay valid with any layout**: on the classic
preset they render byte-identically, on another layout they follow the same roles and directions.
`TrackTarget`'s presets (`.centerOnly`, `.sides`, `Preset.left/right`) map 1:1 onto role and ordering
targets (left/right become "left half"/"right half" of the x ordering).

### Group masters and direct commands
- Each group has its own intensity master. `ShowSettings` and `CustomScene` store
  `masters: [RigGroupID: Double]`; the three role faders become N faders generated from the groups, and MIDI
  `.level` actions take a group id. The global master and blackout stay above everything.
- Groups can be selected in the preview for direct commands: colour, intensity, flash, solo and mute.
  These are engine-side overrides keyed by group id, layered in a fixed order per frame:
  scene → **per-group colour override** (replaces the scene's colour, keeps its intensity shape) →
  per-group master → **solo/mute** (solo darkens every non-soloed group, mute darkens the group) →
  global master → **blackout**. Blackout always wins over every override, and nothing is ever written to
  strobe, macro or program channels. Overrides are performance state, not saved in scenes.

### Saved-file compatibility
Every decoder keeps reading today's keys, as `TrackTarget` and `ShowSettings` already do with `decodeIfPresent`:

| File | Old field | New decoding |
|---|---|---|
| patch | `role: "left"` / missing | `group = "left"`; missing role keeps `Patch.roles` guessing, now returning classic ids |
| patch | no `layout` | `RigLayout.classic` |
| scenes | `leftLevel/centerLevel/rightLevel` | `masters["left"/"center"/"right"]` |
| scenes | `TrackTarget{left,center,right,segments,cobs}` | role/ordering target; centre mask on `"center"` |
| show.json | `levelLeft/Center/Right` | `masters[...]` |
| MIDI map | `.level(left)` | `.level(group "left")` |

Writers emit the new keys **and** the old ones while the layout is `.classic`, for one release, so a
downgrade still opens the files; the scenes envelope `version` is bumped only when a non-classic layout is
saved, and the existing "file comes from a newer version" path protects older builds. Each step adds a
`SceneBankCompatibilityTests`-style test with a JSON sample taken from the current release.

### Preview
- The shadow rig is derived from the layout, not from `VarytecRig.referenceRig()`: every group with no
  patched fixture gets one preview-only placeholder of the group's shape kind. The classic preset still
  shows the familiar three lights.
- `StageLayout` places fixtures by group position, rotation, scale and fixture offset (2D, not a single
  row) and draws each fixture by its group's `shape`, with as many zones as its profile has segments (the
  facet angle already divides by a zone count; it becomes a parameter instead of 6). `isLarge(profileID:)`
  and its `tri380` substring check go away.
- ADR 0004 is unaffected: the preview still decodes the composed DMX bytes.

## Implications for the UI
The UI redesign proposal builds on groups from the start, never on `left/center/right`; this model is
what it needs:
- **Stage canvas.** The preview is a 2D canvas of groups and their fixtures at their stored positions.
  Dragging a group or a fixture writes `RigGroup.position` / `PatchedFixture.offset` (undoable, saved with
  the patch); nothing is recomputed on the 30 Hz path except reading the cached `StageLayout`.
- **Group editing in place.** Select fixtures on the canvas to create or change a group; rename, recolour
  or reorder groups in a side list. Segment and COB counts come from the profiles, shown per fixture.
- **Scene editor.** Track targets are picked on the same canvas (click groups, or segments inside a
  group), or chosen as a role or spatial ordering; the five classic buttons become presets of these. Motion
  previews follow the real positions.
- **Live controls.** One master fader per group, generated from the layout, in the group's label colour;
  MIDI learn binds to a group id. The classic preset shows exactly today's three faders. Selecting groups
  in the preview opens direct commands (colour, intensity, flash, solo, mute).
- **Views share one model.** `RigLayout` + `Patch` + `EngineSnapshot` (fixture visuals with group id and
  position) are everything a view needs, so new views (a compact live view, a large canvas, a scene
  miniature) can be added without touching RaysCore. The preview stays a decoder of the real DMX bytes
  (ADR 0004).

## Incremental plan
Each step is one small PR, green on its own. The engine group model comes first (steps 1–6, no visible
behaviour change on the classic preset); the free-layout stage and per-group faders in the UI come after
it (steps 7–8).

1. **Golden frames.** Add a fingerprint test that renders every scene and bank on the classic rig at fixed
   beats and stores the hashes (extend `FingerprintRegressionTests`). Every later step must keep them.
2. **`RigLayout` and ids.** Add `RigGroupID`, `RigGroup` (position, shape, label colour, roles, master),
   `RigLayout.classic`, optional `Patch.layout` and `PatchedFixture.group` with decoding tests for old
   patches. Nothing reads them yet.
3. **`RigFrame` over groups.** Change storage to `[GroupFrame]` with `left/center/right` computed
   accessors and the `FixtureRole` subscript kept. Golden frames unchanged; allocation-free check on the
   30 Hz path.
4. **Spatial targets.** Generate `SceneLook.rgbX/cobX` from group positions; `TrackTarget` gains role,
   ordering and explicit-group targets with old-key decoding. Golden frames unchanged.
5. **Group masters and overrides (engine).** `masters: [RigGroupID: Double]` in `CustomScene`,
   `ShowSettings` and MIDI routing, with dual-key writing and compatibility tests; engine-side per-group
   colour override, flash and solo/mute in the order above, with blackout-wins tests.
6. **Engine and preview model.** `LightEngine` builds frames and the shadow rig from the patch layout;
   `StageLayout` takes shapes, segment counts and 2D positions; `FixtureVisual` carries group id and
   position. Choreographies checked on 1, 2, 4 and 5 groups with numeric tests (peaks, chase order by x,
   no strobe/program channel ever above 0).
7. **Free-layout stage (UI).** Draggable groups and fixtures on the canvas, group editor (name, label
   colour, shape, assign fixtures), scene targets picked on the canvas; localized strings in `it.lproj`.
   First user-visible change.
8. **Per-group faders and direct commands (UI).** N faders generated from the groups, MIDI learn per
   group, selection on the canvas for colour, intensity, flash, solo and mute.
9. **Cleanup.** Deprecate `FixtureRole` in public API once nothing in RaysCore uses it; stop writing the
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
- Role and ordering targets replace booleans in `TrackTarget`, so the scene editor needs a canvas picker
  once more than three groups exist.
