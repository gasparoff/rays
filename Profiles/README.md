# Fixture profiles

Each `*.json` file here describes one light in one DMX mode. They're bundled into
`RAYS.app` and loaded at startup next to the built-in profiles.

Naming: `<manufacturer>.<model>-<mode>.json`, all lowercase, e.g. `varytec.pad7-rgbwa-10ch.json`.
How to write one: [docs/adding-a-fixture.md](../docs/adding-a-fixture.md).

Subfolders are loaded too. `ofl/<manufacturer>/<fixture>.json` holds profiles converted from the
[Open Fixture Library](https://open-fixture-library.org) (MIT) by `Scripts/import-ofl.py`: one
file per fixture, one profile per DMX mode RAYS can drive safely. They are not verified on
hardware. To refresh them, clone OFL and run
`python3 -I Scripts/import-ofl.py <ofl-checkout> --out Profiles/ofl`; please don't hand-edit
these files, fix the fixture in OFL instead (or add a hand-written profile next to them).
