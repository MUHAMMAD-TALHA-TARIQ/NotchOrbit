# Contributing to NotchOrbit

Thanks for wanting to help. Bug reports, fixes and focused features are all welcome.

## Building

```bash
./build.sh debug && open build/NotchOrbit.app
```

Requirements and troubleshooting are in [docs/GETTING_STARTED.md](docs/GETTING_STARTED.md);
how the code is organised is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Reporting a bug

Please include:

- the NotchOrbit version (top of the menu-bar menu) and your macOS version,
- the Mac model and whether an external display is connected,
- what you did, what you expected and what happened,
- output from `NOTCHORBIT_DEBUG=1 build/NotchOrbit.app/Contents/MacOS/NotchOrbit` if
  the problem is about geometry, clicks or stats.

Do not attach screenshots or recordings that show other people's faces.

## Pull requests

- Keep a pull request to one change, and describe how you tested it. There is no unit
  test target; say what you ran and what you saw (which Mac, which display setup).
- The project has no third-party dependencies. Please keep it that way unless there is
  a strong reason; discuss it in an issue first.
- Follow the style of the surrounding code: AppKit views drawn by hand, a doc comment
  on each type saying what it is for, comments that explain why rather than what.
- New options go into `AppSettings` (they must have defaults so older settings keep
  loading) and onto the Settings page of the feature they belong to.
- The app is built to stay small and idle cheaply. Create expensive objects on first
  use and release them when their feature closes; mention any change in footprint
  (`footprint -p $(pgrep -x NotchOrbit)`).
- User-visible changes get a line in `CHANGELOG.md` and, where relevant, in `docs/`.

## Face Transform changes

Changes to Face Transform must keep its safeguards: the per-session confirmation by
the person on camera, the two attestations at enrolment, and the server-drawn
AI TRANSFORMED badge. Pull requests that remove or bypass them, or that aim to evade
detection, will not be accepted.

## Licence

By contributing you agree that your contribution is licensed under the MIT License.
