# Add a MIDI controller

Any MIDI controller can already drive RAYS through **MIDI Learn** (Configurazione → Controller),
and Learn bindings always override a layout. A **controller layout** goes further: it is a JSON
file in `Controllers/` that says which note or CC drives each action, which knobs are endless
encoders and how the pad LEDs are addressed. No Swift needed.

> **Status.** The format, loader and validation are in place, and the Xone:K2 Classic and
> Live v2 layouts ship as JSON. The K2 is still routed by the built-in `XoneK2` code (tests
> prove the JSON files are identical to it). Routing other controllers straight from their
> layout file is the next step on the [roadmap](architecture.md#roadmap). Layouts you add now
> are validated by CI and will work as soon as that lands.

## 1. Agree on the mapping

Open an issue with the [new controller template](../../../issues/new?template=new-controller.yml)
so we can agree on the action mapping first. Check the device's MIDI implementation chart
(manual) or watch what it sends with a MIDI monitor.

## 2. Write the file

`Controllers/<manufacturer>-<model>[-<layout>].json`, all lowercase. One object per file (an
array of objects is also accepted).

```json
{
  "id": "acme.padbox-16",
  "name": "PadBox 16",
  "manufacturer": "Acme",
  "portNamePattern": "padbox",
  "midiChannel": 1,
  "bindings": [
    { "action": "master",  "type": "cc",   "number": 7 },
    { "action": "energy",  "type": "cc",   "number": 1 },
    { "action": "scene1",  "type": "note", "number": 36 },
    { "action": "accent",  "type": "note", "number": 44 },
    { "action": "blackout","type": "note", "number": 51 }
  ],
  "relativeEncoders": [1],
  "encoderResolution": 100,
  "leds": {
    "notes":  { "from": 36, "to": 51 },
    "colors": { "red": 0, "amber": 16, "green": 32 }
  },
  "notes": "Factory preset 1. Fader = master, encoder 1 = energy, pads 1–6 = scenes."
}
```

| Field | Required | Meaning |
|---|---|---|
| `id` | yes | Unique, `manufacturer.model[-layout]`. A file in Application Support with the same id replaces the bundled one. |
| `name`, `manufacturer` | yes | Shown in the app. |
| `portNamePattern` | yes | Case-insensitive regular expression matched against the CoreMIDI port name. |
| `midiChannel` | yes | 1…16, as printed in manuals. |
| `bindings` | yes | `action` + `type` (`note` or `cc`) + `number` (0…127). One control per action, one action per control. |
| `relativeEncoders` | no | CC numbers of endless encoders sending two's-complement deltas (1 = +1, 127 = −1). |
| `encoderResolution` | no | Detents for a full 0…1 sweep on a bound encoder (default 100). |
| `leds` | no | Pads in `notes.from…to` light colour *c* by sending note `base + colors.c`. `special` lists buttons with their own `[red, amber, green]` addresses. |
| `notes` | recommended | One or two lines describing the layout. |

### Actions

Continuous (need a `cc`): `master`, `energy`, `levelLeft`, `levelCenter`, `levelRight`,
`accentLevel`.

Buttons (`note`, or a `cc` that goes ≥ 64 when pressed): `scene1`…`scene6`, `accent` and
`buildDrop` (held), `blackout`, `stop`, `output`, `rateQuarter`, `rateHalf`, `rateNormal`,
`rateDouble`, `bankHouse`, `bankClub`, `sceneFirstBeat`, `cancelPending`.

The full list with descriptions is `ControlAction` in `Sources/RaysControl/MIDIMapping.swift`.

## 3. Test

```sh
swift test --filter CommunityControllersTests
```

The test decodes every file in `Controllers/` and fails with a readable message on: unknown
actions, channel outside 1…16, a continuous action on a note, a control bound twice, a button on
an endless encoder, LED addresses above 127, or a duplicate id. To try a layout without
rebuilding, copy it to `~/Library/Application Support/Light System/Controllers/`: invalid files
are listed in Setup.

## 4. Document it

Add a short `docs/controllers/<name>.md` with a picture of the mapping, and a row in the
README's hardware table.
