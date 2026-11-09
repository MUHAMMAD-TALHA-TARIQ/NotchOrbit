# NotchOrbit

A tiny macOS menu-bar app that puts circles on either side of the MacBook notch
(plain, or live system-stat gauges) and lets you reshape the notch with a black overlay.

![sample](Assets/sample.gif)

## Features

- **Circles beside the notch** – a tinted disc on each side of the notch. Show or hide
  either side and adjust size, gap, vertical offset and border.
- **Notch shapes** – *Original*, *Rounded*, *Island (pill)*, *Square*, *Wide* presets,
  plus a *Custom* mode with sliders for extra width, extra height, bottom corner radius
  and top "ear" radius. Overlay colour is configurable too.
- **Dynamic Island on external displays** – monitors (or Macs) without a notch get a
  virtual black island at the top centre, with the circles beside or inside it. Width,
  height, distance from the top edge and corner radius are adjustable; distance 0 hangs
  it from the edge like a notch, anything else floats it as a pill.
- **Attach mode** – the overlay can wrap around the circles so they become part of the
  notch / island.
- **System stats mode** – fill the circles with live readings: the left circle becomes a
  ring gauge for CPU, memory, GPU, disk, battery or the number of running apps (pick one
  from a dropdown), and the right circle shows 🔥 when the reading is above an adjustable
  threshold and ❄️ when it isn't. The emoji is animated: above the threshold it flickers
  like a flame over rising embers, below it slowly turns while snowflakes fall past it
  (toggle in the Stats tab; off automatically with Reduce Motion). Click the emoji to
  fill the whole screen with fire or snow for 3–20 seconds (adjustable). Click the gauge to expand
  the notch downward into a panel (click the gauge again or anywhere else to collapse).
  Its tab row holds a **Stats tab** (every reading in a row; click one for its history
  graph), a **Camera tab** with a live webcam preview (outline selectable in Settings:
  rounded rectangle, rectangle, square, circle or capsule), a photo shutter and a
  microphone level meter (camera and mic only run while that tab is open; macOS asks for
  permission the first time), a **Mic tab** beside it that turns the microphone into a
  voice changer: pick one of ten effects (Normal, Deep, Chipmunk, Robot, Echo, Cathedral,
  Radio, Alien, Monster, Underwater), fine-tune pitch (±12 semitones) and effect amount,
  watch a live level meter, click the microphone name to pick which mic to listen to, *Play Through* to hear yourself (wear headphones), *Record*
  the changed voice to an .m4a, and *Stay On* to keep the playthrough running after the
  panel closes. **Use as Mic** turns the changed voice into a microphone for calls:
  NotchOrbit plays it into a virtual loopback device, publishes that to macOS as a device
  called **NotchOrbit Microphone** and makes it the system microphone, so FaceTime uses it
  automatically; Teams, WhatsApp, Zoom, Slack, Discord… pick "NotchOrbit Microphone" (or
  "Same as system") in their microphone setting. Your real microphone is put back when
  you switch it off or quit. The loopback driver is [BlackHole](https://existential.audio/blackhole/) (free, open
  source); if it isn't installed, Settings offers a one-click download that verifies the
  package's checksum and opens the installer. The same toggle is in the menu-bar menu,
  and it resumes at the next launch. **Echo cancellation** (on by default) captures your
  real mic through Apple's voice processing, so the other side of a call playing from your
  speakers isn't sent back to them with the effect on it. The output device (and, with
  echo cancellation off, the microphone) is also selectable in Settings. A **screenshot button**, a **record / stop button** with
  an elapsed-time counter (captures go to Downloads or any folder chosen in Settings;
  NotchOrbit's overlay is excluded from them) and a **gear button** that opens Settings.
  Each stat remembers its own threshold; the emoji
  shown above and below the threshold are fully customisable (quick picks or the system
  emoji picker), as is the refresh interval.
- **Weather mode** – show the current weather in the right circle instead of a plain disc
  or the stats emoji: condition as an emoji (☀️ ⛅️ 🌧️ ⛈️ 🌨️ …, night-aware) or a colour SF
  Symbol, with the temperature to its left (the circle stretches into a capsule). Weather is fetched
  from [Open-Meteo](https://open-meteo.com) (free, no account) for your current location
  (Core Location, asked once) or a city picked from a search box; Celsius, Fahrenheit or
  the system setting; refresh interval 5–60 minutes. Click the circle to fill the screen
  with the current weather for 3–20 seconds (sunshine, a starry night, drifting clouds,
  fog, rain, a thunderstorm with lightning flashes, or snow); the click also refreshes
  the forecast. Works with or without system stats mode. With stats mode on, the expanded
  panel gets a **Weather tab** beside the camera button: an animated scene of the current
  conditions behind the temperature, feels-like, humidity, wind, today's high/low and an
  hourly strip with a temperature curve.
- **Settings window** – sidebar layout (Notch Shape, Circles, Dynamic Island, System
  Stats, Weather, General) with live 1:1 previews, camera/microphone permission status, a
  reset-to-defaults action and version info.
- Clicks on the overlay itself (the notch / island shape, the circles, the expanded panel)
  are swallowed so they never reach the app behind; everywhere else the menu bar and
  desktop get clicks as usual.
- Works over full-screen apps and on every Space; follows display changes.
- Menu-bar only (no Dock icon), optional launch at login, settings persist.

## Install (DMG)

Download `NotchOrbit-<version>.dmg`, open it and drag **NotchOrbit** onto the
**Applications** shortcut in the window. Launch it from Applications; it appears as a
half-filled circle in the menu bar (no Dock icon).

The DMG is a universal build (Apple silicon + Intel, macOS 13+) and ships with a
`.sha256` checksum file and a *Read Me* with the steps below.

Builds that are not notarized are held back by Gatekeeper on first launch:

- **macOS 15 or later** – macOS says the app "could not be verified". Click *Done*, open
  System Settings › Privacy & Security, scroll down and click **Open Anyway** next to
  NotchOrbit, then confirm. This is needed once.
- **macOS 13 / 14** – right-click the app in Applications, choose *Open*, then *Open*.
- **Terminal alternative** – `xattr -dr com.apple.quarantine /Applications/NotchOrbit.app`

The Camera tab, the Mic tab and the screenshot/recording buttons each ask for their
permission the first time they are used (Screen Recording needs a relaunch). Weather set
to "Current location" asks for Location access once; choosing a city needs no permission.

## Build & run

Requires macOS 13+ and the Xcode Command Line Tools (no full Xcode needed).

```bash
./run.sh            # build release, assemble NotchOrbit.app, launch it
./build.sh debug    # just build (debug) into build/NotchOrbit.app
./make-dmg.sh       # release build + branded DMG → build/NotchOrbit-<version>.dmg
./build.sh clean    # remove build/ and SwiftPM's .build/ (it grows to ~1 GB)
```

Release builds are optimised for size (`-Osize`), fully stripped and universal.
`ARCHS=arm64 ./build.sh` makes an Apple-silicon-only build at about half the binary size.

`build.sh` signs ad-hoc by default, which is fine for your own Mac. For distribution,
sign with a Developer ID certificate; the app then gets the hardened runtime plus
`NotchOrbit.entitlements` (camera + microphone), and the DMG is signed too:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./make-dmg.sh
xcrun notarytool submit build/NotchOrbit-*.dmg --keychain-profile <profile> --wait
xcrun stapler staple build/NotchOrbit-*.dmg
```

The DMG window layout (background, icon positions) is applied through Finder, so the
first run of `make-dmg.sh` may ask to allow your terminal to control Finder.

### Releasing a new version

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Info.plist`.
2. If the icon or DMG artwork changed, regenerate assets:
   `swiftc -O Tools/generate-assets.swift -o /tmp/gen && /tmp/gen Assets`
   (the generator renders in 16-bit and converts to 8-bit afterwards; Core Graphics
   dithers gradients drawn straight into 8-bit bitmaps, which made the PNGs 4–5× larger)
3. `./make-dmg.sh` (with `SIGN_IDENTITY` for a public release), then notarize and staple.
4. Keep `build/NotchOrbit.dSYM` with the release for symbolicating crash reports.

## Project layout

```
Package.swift                  SwiftPM manifest (executable target)
Info.plist                     bundle metadata (LSUIElement = menu-bar app)
build.sh / run.sh / make-dmg.sh  assemble NotchOrbit.app, launch, package a DMG
Assets/                        app icon, DMG background (HiDPI TIFF), sample GIF (from Tools/generate-assets.swift)
CHANGELOG.md                   release notes
NotchOrbit.entitlements        hardened-runtime entitlements used with SIGN_IDENTITY
Sources/NotchOrbit/
  main.swift                   app bootstrap
  AppDelegate.swift            status item, menu, first-launch defaults, Settings window lifetime
  Debug.swift                  NOTCHORBIT_DEBUG flag (read once) and debugLog
  Settings.swift               model, UserDefaults store (writes coalesced)
  NotchGeometry.swift          one overlay target per display: real notch or virtual island
  NotchShapeBuilder.swift      CGPath for the overlay shape
  OverlayWindow.swift          transparent click-through NSPanel above the menu bar
  OverlayView.swift            draws the shape and positions the circles; sizes the window to the overlay
  CircleDiscView.swift         plain tinted disc
  StatViews.swift              stats mode circles: ring gauge (left) and emoji badge (right)
  StatsPanelView.swift         expanded panel: stats tab + graph, camera tab, screenshot / record, gear (tabs built on demand)
  PanelDrawing.swift           tinted SF Symbol cache and text helpers shared by the panel views
  ToastView.swift              fading confirmation message used by the panel and camera view
  CameraPreviewView.swift      AVCaptureSession webcam preview, photo / screenshot / record buttons
  ScreenCaptureService.swift   screenshots and recordings via /usr/sbin/screencapture
  MicLevelView.swift           AVAudioEngine input tap drawn as a segmented level meter
  VoiceChanger.swift           Mic tab engine: mic → sink/ring buffer → pitch, distortion, EQ, delay, reverb → output; recording; device aggregate; virtual microphone (loopback + default input)
  BlackHoleInstaller.swift     downloads the BlackHole 2ch package, verifies its SHA-256 and opens Installer
  MicPanelView.swift           panel Mic tab: effect grid, pitch / effect / volume sliders, playthrough, record, stay-on
  SystemStats.swift            CPU / memory / GPU / disk / battery / app-count sampler
  WeatherService.swift         Open-Meteo fetch + Core Location / city search, WMO code → condition
  WeatherBadgeView.swift       weather mode badge (right): temperature + condition capsule
  WeatherPanelView.swift       panel Weather tab: animated scene, details, hourly curve
  SettingsView.swift           SwiftUI settings: sidebar pages, previews, emoji field, privacy & reset
  SettingsWindowController.swift
```

## Footprint

NotchOrbit is built to stay out of the way when idle:

- The overlay window is only as large as the overlay itself (a strip around the notch,
  grown while the panel is open), and the shape layer is sized to the shape, not the
  window. Panel tabs are created when first opened; the camera pipeline is released
  whenever the panel closes, and the Settings window is released when it closes.
- Core Location, the audio HAL and the voice engine are only loaded by the features
  that use them (weather for the current location, the Mic tab / Use as Mic).
- Stats sampling pauses while the displays sleep; the GPU reading fetches one IO
  registry property instead of copying every accelerator property each tick; settings
  writes are coalesced; mouse tracking rejects most moves with one bounds check.
- "Use as Mic" with echo cancellation keeps Apple's voice-processing audio unit running
  for the whole session. That unit brings its own noise-suppression model and accounts
  for most of the memory in that mode; turn echo cancellation off if memory matters
  more than call quality.

## Notes

- The hardware notch can't be hidden; the overlay paints black over the menu bar
  around it so it *looks* wider, taller, squarer or pill-shaped.
- Set `NOTCHORBIT_DEBUG=1` when launching the executable to log the detected
  geometry and each stats sample to stderr. Add `NOTCHORBIT_DEBUG_TAB=mic` (or `stats`,
  `weather`, `camera`) to open the panel on that tab right after launch.
- Voice effects run on two engines. The capture side owns the microphone: with echo
  cancellation it is Apple's `VoiceProcessingIO` audio unit driven directly (echo
  cancellation, noise suppression and gain control, with the system default output as the
  echo reference — it cancels audio played by *other* processes, i.e. the other side of a
  call). Its input side is pinned to the real microphone (`kAudioOutputUnitProperty_CurrentDevice`
  on the input scope, element 1) because the system default input is the loopback device
  while "Use as Mic" is on; the unit needs ~0.5 s between that and initialisation or its
  input side never starts, so the start is delayed, verified and retried. Otherwise the
  capture is an AVAudioEngine input node on the chosen mic. `AVAudioEngine`'s own `setVoiceProcessingEnabled` fails to initialise on
  Apple-silicon MacBooks under macOS 27, which is why the unit is used bare. Either way
  the frames go into a small ring buffer that an `AVAudioSourceNode` in the playback
  engine drains into the effect chain and out to the chosen output device (one device
  buffer of latency, ~10 ms). AVAudioEngine won't feed the
  input node into a converter-type unit such as `AVAudioUnitTimePitch`, which is the other
  reason for the split. The macOS reverb only renders stereo, so the chain is mono up to
  the reverb and stereo after it. An I/O unit serves both directions from a single device,
  so an output-only device (speakers) or a non-default mic is wrapped in a private
  aggregate device for the duration.
- "Use as Mic" needs a loopback driver because only an audio driver can present a new
  input device to other apps. NotchOrbit looks for BlackHole, Loopback, VB-Cable or
  Soundflower (a device with both an input and an output side), plays the processed voice
  into it, publishes a public aggregate device named "NotchOrbit Microphone" (UID
  `com.talha.NotchOrbit.microphone`) that wraps it — so other apps' pickers show
  NotchOrbit's name instead of the driver's — and sets that as the system default input
  (FaceTime's microphone picker *is* the system default). Public aggregates survive the
  creating process, so the device is reused if it already exists and removed on disable,
  quit and at launch when the feature is off. NotchOrbit's own capture is always pinned to a real microphone, and the
  capture restarts when the default devices change, so the loopback device can never feed
  back into itself. The real mic is restored on disable, quit and at launch.
- Weather: one request to `api.open-meteo.com` per refresh (coordinates only; no account,
  no tracking) and `geocoding-api.open-meteo.com` for the city search. The last reading is
  cached for up to three hours so the circle has something to show right after launch.
- Stats readings: CPU is the busy share of all cores since the previous sample; memory
  matches Activity Monitor's "Memory Used" (app + wired + compressed); GPU comes from the
  graphics driver's `Device Utilization %` counter in the IO registry; disk is the used
  share of the startup volume; battery is the internal battery's charge (hidden on
  desktops); apps counts applications that show in the Dock / ⌘-Tab switcher, and the
  ring is full at 20 of them.
