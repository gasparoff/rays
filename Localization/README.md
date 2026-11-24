# Translations

RAYS is written in English. Every user-facing string in `Sources/` is either a SwiftUI literal
(`Text("Save")`, `Button("Cancel")`) or `String(localized: "…")`, and the English text is the key.

Each language is a folder here, copied into `RAYS.app/Contents/Resources` by `Scripts/build-app.sh`:

| File | What it holds |
|---|---|
| `<lang>.lproj/Localizable.strings` | `"English text" = "Translation";` |
| `<lang>.lproj/InfoPlist.strings` | System prompts, e.g. the Local Network permission text |

Interpolated values appear as `%@` in keys (`"Bank %@" = "Banco %@";`). If your language needs them in a
different order, number them: `"%@ of %@" = "%2$@ … %1$@";`. `LocalizationTests` fails if a translation
loses or adds a placeholder.

## Add a language

1. Copy `it.lproj` to `<code>.lproj` (for example `de.lproj`, `es.lproj`, `pt-BR.lproj`).
2. Translate the right-hand side of every line. Keep the keys exactly as they are.
3. Run `make test`, then build with `Scripts/build-app.sh`: the new folder is picked up on its own.
4. Open the app, choose your language in Setup › Advanced › Language, restart, and check every window.

## Choosing the language

RAYS follows the macOS language by default. Setup › Advanced › Language overrides it for RAYS only (the
same setting as System Settings › General › Language & Region › Applications) and applies after a restart.

Fixture profile data (names, modes, notes) is not translated: it is part of the patch fingerprint
that confirms a rig is wired correctly.
