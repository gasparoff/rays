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

## 4. Test it

```sh
swift test --filter CommunityProfilesTests
```

The test checks JSON validity, unique ids and channel sanity. Then try it in the app:
**Configurazione → Luci**, pick your profile, use the red/white 5-second test.

## 5. Open a PR

Title: `fixture: Acme Spot RGB (7 CH)`. Include the manual link and whether you
tested it on hardware. Thank you!
