# Add a fixture profile

A fixture profile tells RAYS what each DMX channel of a light means. RAYS computes the
values; the profile only maps them. **No Swift required.**

## 1. Find the channel table

Open the official manual of your light and find the table for the DMX mode you use
(e.g. "8 CH mode"). Note the page number: you'll cite it.

## 2. Copy the template

```sh
cp Profiles/community.generic.par-rgbw-6ch.json Profiles/acme.spot-rgb-7ch.json
```

## 3. Describe every channel, in order

| `kind` | Meaning |
|---|---|
| `dimmer` | Master dimmer of the fixture |
| `red`, `green`, `blue`, `amber` | Color emitters |
| `white` | White LED mixed with the color |
| `blinder` | Independent white/COB element (blinders, warm white strips) |
| `constant` | Fixed value from `value` (e.g. shutter open = 255) |
| `ignore` | Sent as 0: strobe, macros, programs, sound mode, UV (no UV colour yet)… |

Rules:

- The number of entries **must equal** the channel count of the mode.
- Strobe, macro, program and sound-to-light channels are always `ignore`. RAYS never
  triggers internal programs.
- Pixel fixtures: repeat `red/green/blue` per segment, in physical order. Use `"segment": n`
  only if the manual interleaves channels unusually.

```json
{
  "id": "acme.spot-rgb-7ch",
  "name": "Spot RGB",
  "manufacturer": "Acme",
  "mode": "7 CH",
  "isGeneric": false,
  "isVerified": false,
  "notes": "Manual v2.1, p.12. https://example.com/manual.pdf",
  "channels": [ { "kind": "dimmer", "value": 0 }, … ]
}
```

Set `"isVerified": true` **only** if you tested the profile on the physical light.

## 3b. Optional: how the preview draws it

The stage preview draws each light from its profile. By default RAYS infers the shape from
the channels: several repeated `red/green/blue` groups are a **bar** with its zones left to
right in channel order, a single colour group is a **PAR**, white/blinder channels alone are a
**blinder**. When that is not what your light looks like, add an optional `visual` key:

```json
"visual": { "kind": "bar", "zones": "horizontal" }
```

| Key | Values |
|---|---|
| `kind` | `triangle`, `par`, `bar`, `wash`, `spot`, `movingHead`, `strip`, `blinder`, `generic` |
| `zones` | Optional order of the RGB zones: `horizontal` (left → right), `vertical` (top → bottom), `radial` (around the centre, clockwise from the top), `grid` |
| `columns` | Only with `"zones": "grid"`: zones per row (1 or more) |

The preview then draws a PAR as a round can with its LED array, a bar or strip as a row of pixels, a
`wash` as an LED panel, a `spot` or `movingHead` as a head on its yoke and a `blinder` as round COB
cells, each zone and white emitter coloured from the DMX values.

`visual` only changes the drawing: it never changes a DMX value, and it is not part of the
patch fingerprint, so adding it never un-confirms a patch. `CommunityProfilesTests` checks it.

## 4. Test it

```sh
swift test --filter CommunityProfilesTests
```

The test checks JSON validity, unique ids, channel sanity and the `visual` key. Then try it in the app:
**Configurazione → Luci**, pick your profile, use the red/white 5-second test.

## 5. Open a PR

Title: `fixture: Acme Spot RGB (7 CH)`. Include the manual link and whether you
tested it on hardware. Thank you!
