# Add a MIDI controller

Any MIDI controller can already drive RAYS through **MIDI Learn** (Configurazione → Controller),
and Learn bindings always override a layout. A **controller layout** goes further: it is a JSON
file in `Controllers/` that says which note or CC drives each action, which knobs are endless
encoders and how the pad LEDs are addressed. No Swift needed.

## How a layout is used

- RAYS connects every MIDI input whose name matches a layout's `portNamePattern` and routes its
  messages through that layout, on the layout's channel. Learned bindings always win.
- If the layout has `leds`, pads light up with the same colour rules as the K2 (amber = preview
  or selection, green = real output, red = blackout), sent to the MIDI output with a matching name.
- Setup → Controller shows the mapping of each connected layout.
- Inputs that match no layout are ignored, unless **"Ascolta tutti gli ingressi MIDI per
  «Impara»"** is switched on in Setup (off by default): then they can be mapped with Learn.
- The Xone:K2 always uses the built-in layouts (`XoneK2.classicProfile` / `liveV2Profile`),
  which also work when no layout files are present. `Controllers/xone-k2-*.json` are tested to
  be identical to them, so they double as reference examples.

Layouts other than the K2 are community contributions and are not verified on hardware unless
the README's hardware table says so.

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
| `bindings` | yes | `action` + `type` (`note` or `cc`) + `number` (0…127), optional `channel` (1…16) when this control sends on another channel than `midiChannel` (e.g. per-track faders). One control per action, one action per control. |
| `relativeEncoders` | no | CC numbers of endless encoders sending two's-complement deltas (1 = +1, 127 = −1). |
| `encoderResolution` | no | Detents for a full 0…1 sweep on a bound encoder (default 100). |
| `leds` | no | `style` `offset` (default, Xone:K2): pads in `notes.from…to` light colour *c* by sending note `base + colors.c`; `special` lists buttons with their own `[red, amber, green]` addresses. `style` `velocity` (Akai APC, Novation): the pad's own note with velocity `colors.c`; `extraNotes` adds LED notes outside the range. LEDs are sent on each binding's channel. |
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
rebuilding, copy it to `~/Library/Application Support/RAYS/Controllers/`: invalid files
are listed in Setup.

## 4. Document it

Add a short `docs/controllers/<name>.md` with a picture of the mapping, and a row in the
README's hardware table.
