# Controller layouts

Each `*.json` file here describes one MIDI controller layout: which note or CC drives
which RAYS action, which CCs are endless encoders, and how the pad LEDs are addressed.
They are bundled into `RAYS.app` (`Contents/Resources/Controllers`) and loaded at startup
together with `~/Library/Application Support/Light System/Controllers/*.json`.

The two Xone:K2 files mirror the built-in layouts exactly; `swift test` fails if they drift.
Naming: `<manufacturer>-<model>[-<layout>].json`, all lowercase.
How to write one: [docs/adding-a-controller.md](../docs/adding-a-controller.md).
