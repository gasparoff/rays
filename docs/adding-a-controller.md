# Add a MIDI controller

Any MIDI controller already works through **MIDI Learn** (Configurazione → Controller).
A built-in layout goes further: zero setup, LED feedback and an on-screen guide.

## How controllers work today

- `Sources/LightCore/MIDIMapping.swift` defines every `ControlAction` (scenes, faders,
  Flash, Build → Drop, Blackout…) and the `MIDIRouter` that turns MIDI into commands.
- `enum XoneK2` is the reference layout: note/CC numbers per action, LED addresses and
  colors, relative encoders.
- User Learn bindings always override a built-in layout.

## Adding a layout

1. Open an issue with the [new controller template](../../../issues/new?template=new-controller.yml)
   so we can agree on the action mapping first.
2. Follow the `XoneK2` pattern: a namespace with the factory MIDI channel, a
   `preset` table of `(action, kind, number)` and, if the device has LEDs, their addresses.
3. Add tests modeled on `Tests/LightCoreTests/MIDIMappingTests.swift` and
   `XoneLiveLayoutTests.swift`: every action reachable, no two actions on one control.
4. Document the layout in `docs/controllers/<name>.md` with a picture of the mapping.

> Planned: a `ControllerProfile` JSON format, so simple layouts need no Swift at all.
> See [architecture.md](architecture.md#roadmap). Help is welcome.
