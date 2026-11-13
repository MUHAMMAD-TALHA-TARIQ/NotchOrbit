# Getting started

## Requirements

| | Minimum |
|---|---|
| macOS | 13 (Ventura) |
| Hardware | Any Mac. Notch features need a MacBook with a notch; other displays get the Dynamic Island |
| To build | Xcode 15 or later (Swift 5.9+) in /Applications |

Nothing else is needed for the core app: there are no package dependencies, and the
build is a plain `swift build`. The Command Line Tools on their own fail on current SDKs
with *plugin for module 'SwiftUIMacros' not found*, because SwiftUI's macros ship only
with Xcode. `build.sh` uses an Xcode from /Applications automatically when the Command
Line Tools are the selected toolchain; for a bare `swift build`, either run
`sudo xcode-select -s /Applications/Xcode.app` once or prefix the command with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. Optional extras (a loopback audio driver, the face
server, OBS) are listed in the README and only matter for the features that use them.

## Build and launch

```bash
git clone https://github.com/MUHAMMAD-TALHA-TARIQ/NotchOrbit.git
cd NotchOrbit
./run.sh
```

`run.sh` runs `build.sh release`, which

1. builds with `swift build -c release` for arm64 and x86_64, optimised for size,
2. assembles `build/NotchOrbit.app` (executable, `Info.plist`, icon),
3. strips the binary and keeps the symbols in `build/NotchOrbit.dSYM`,
4. signs ad-hoc (or with `SIGN_IDENTITY` if set),

then quits any running copy and opens the new one. For a faster loop while developing:

```bash
./build.sh debug && open build/NotchOrbit.app
```

A half-filled circle appears in the menu bar. There is no Dock icon; quit from the
menu-bar menu.

## First steps in the app

1. The Settings window opens on first launch. **Notch Shape** and **Circles** change
   what is drawn around the notch; the preview at the top of each page is live.
2. **System Stats** › *Show system stats in the circles* turns the left circle into a
   gauge. Click the gauge to expand the panel; click it again, or anywhere else, to close.
3. The panel's tab row holds Stats, Weather (when weather is on), Mic and Camera, then
   the screenshot, record and gear buttons.
4. **Weather**, **Microphone** and **Camera & Face Swap** each have their own Settings page.
5. **General** holds the overlay switch, launch at login, the capture folder,
   permissions, reset and the version.

## Permissions

macOS asks the first time a feature needs one. If you clicked "Don't Allow", change it
in System Settings › Privacy & Security; Settings › General › Privacy in NotchOrbit has
a shortcut button for each.

| Permission | Why |
|---|---|
| Camera | Camera tab preview and photos; Face Transform |
| Microphone | Level meter in the Camera tab; voice changer |
| Screen Recording | Screenshot and record buttons (relaunch NotchOrbit after allowing) |
| Location | Weather for your current location (not needed if you pick a city) |
| Automation (Finder) | Only `make-dmg.sh`, to lay out the DMG window |

Rebuilding changes an ad-hoc signature, so macOS may ask for camera or microphone
access again after you build a new copy. Signing with a stable identity avoids that.

## Where things are stored

| What | Where |
|---|---|
| Settings | `defaults read com.talha.NotchOrbit` (one JSON blob under `NotchOrbit.settings`) |
| Photos, screenshots, recordings | Downloads, or the folder chosen under Settings › General › Captures |
| Weather cache | In the settings domain; kept for up to three hours |
| Face server log | `~/Library/Logs/NotchOrbit/face-server.log` |

To start over: Settings › General › Reset All Settings, or `defaults delete com.talha.NotchOrbit`.

## Troubleshooting

| Problem | What to check |
|---|---|
| Nothing appears around the notch | Menu-bar menu › Show Overlay is ticked; on a display without a notch, Dynamic Island is enabled |
| "The camera needs the app bundle" | You launched the bare executable; open `build/NotchOrbit.app` instead |
| Screenshot button says it has no permission | Allow Screen Recording, then quit and relaunch |
| Launch at login can't be switched on | It needs the `.app` bundle in a stable location such as /Applications |
| Gatekeeper blocks the app | See the README's Install section |
| `plugin for module 'SwiftUIMacros' not found` | The Command Line Tools are being used; install Xcode, or point `DEVELOPER_DIR` at it |
| `swift build` fails on an old toolchain | `swift --version` must report 5.9 or later; update Xcode |
| The build folder is huge | `./build.sh clean` (SwiftPM's `.build/` grows to about 1 GB) |
| Face Transform won't start | [FACE_TRANSFORM.md](FACE_TRANSFORM.md#troubleshooting) |
| "Use as Mic" problems | [VOICE_CHANGER.md](VOICE_CHANGER.md#troubleshooting) |

For anything else, run with logging and include the output in a bug report:

```bash
NOTCHORBIT_DEBUG=1 build/NotchOrbit.app/Contents/MacOS/NotchOrbit
```
