# Releasing RAYS

A release is a tag. Pushing `vX.Y.Z` runs [`release.yml`](../.github/workflows/release.yml): it tests,
builds `RAYS.app` with the Pro DJ Link helper, signs it, notarizes it when the signing secrets exist,
attests the zip's provenance and publishes the GitHub release.

```sh
git tag v0.2.0 && git push origin v0.2.0
```

Before tagging, move the *Unreleased* entries of [CHANGELOG.md](../CHANGELOG.md) under the new version.
"Run workflow" on the Release workflow builds the same zip as an artifact without publishing anything:
use it to check signing and notarization after changing them.

## Developer ID signing and notarization

Without these secrets the app is signed ad hoc and macOS asks users to approve it the first time.
With them, every Mach-O file is signed with the Developer ID and the hardened runtime, the app is
notarized with `notarytool` and the ticket is stapled, so it opens with a double click.

Repository secrets (Settings → Secrets and variables → Actions), set by the maintainer only:

| Secret | What it is |
|---|---|
| `MACOS_CERTIFICATE_P12` | The **Developer ID Application** certificate with its private key, exported from Keychain Access as `.p12`, then `base64 -i cert.p12` |
| `MACOS_CERTIFICATE_PASSWORD` | The password chosen when exporting the `.p12` |
| `APPLE_API_KEY_P8` | An App Store Connect API key (Users and Access → Integrations → Team Keys, access *Developer*), the downloaded `.p8` file as `base64 -i AuthKey_XXXX.p8` |
| `APPLE_API_KEY_ID` | That key's ID |
| `APPLE_API_ISSUER_ID` | The Issuer ID shown above the keys list |

The certificate is imported into a temporary keychain that is deleted at the end of the job; the API
key file is deleted right after notarization. Locally, `RAYS_SIGN_IDENTITY="Developer ID Application: …"
Scripts/build-app.sh` produces the same signed bundle from your own keychain.

The Pro DJ Link helper is a Java runtime, so it is signed with the entitlements in
[`Scripts/entitlements/beatlink-helper.entitlements`](../Scripts/entitlements/beatlink-helper.entitlements)
(JIT and unsigned executable memory). The RAYS executable itself needs no entitlements.
