# Releasing

## Version number

The version lives in `Info.plist`:

- `CFBundleShortVersionString` is the public version (for example `2.0.0`), following
  [Semantic Versioning](https://semver.org).
- `CFBundleVersion` is the build number, increased by one for every release.

The app reads both at runtime (`AppInfo.version`) and shows them at the top of the
menu-bar menu, in the Settings sidebar and under Settings › General › About. The DMG's
file name comes from the same value, so there is one place to change.

## Steps

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Info.plist`.
2. If the icon or DMG artwork changed, regenerate assets:
   `swiftc -O Tools/generate-assets.swift -o /tmp/gen && /tmp/gen Assets`
   (the generator renders in 16-bit and converts to 8-bit afterwards; Core Graphics
   dithers gradients drawn straight into 8-bit bitmaps, which made the PNGs 4–5× larger)
3. `./make-dmg.sh` (with `SIGN_IDENTITY` for a public release), then notarize and staple.
4. Keep `build/NotchOrbit.dSYM` with the release for symbolicating crash reports.

Also update `CHANGELOG.md` and the version line near the top of `README.md`, then tag
the commit (`git tag -a v2.0.0 -m "NotchOrbit 2.0.0" && git push origin v2.0.0`) and
attach the DMG and its `.sha256` file to a GitHub release for that tag.

Releases are tags on `main`, not branches: `main` is the only long-lived branch, so
there is never a question of which one to clone.

## Signing and notarizing

`build.sh` signs ad-hoc by default, which is fine for your own Mac. For distribution,
sign with a Developer ID certificate; the app then gets the hardened runtime plus
`NotchOrbit.entitlements` (camera and microphone), and the DMG is signed too:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./make-dmg.sh
xcrun notarytool submit build/NotchOrbit-*.dmg --keychain-profile <profile> --wait
xcrun stapler staple build/NotchOrbit-*.dmg
```

The DMG window layout (background, icon positions) is applied through Finder, so the
first run of `make-dmg.sh` may ask to allow your terminal to control Finder.

Without notarization, users have to approve the app once in System Settings › Privacy &
Security (see the README's Install section).
