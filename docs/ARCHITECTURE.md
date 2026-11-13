# Architecture

NotchOrbit is a single SwiftPM executable target with no third-party dependencies. It
uses AppKit for the overlay and panel (hand-drawn views), SwiftUI for the Settings and
Enroll Face windows, AVFoundation for the camera, AVAudioEngine and Core Audio for the
voice changer, and URLSession for the weather and the face server.

## How the overlay works

- Each display gets one transparent, click-through `NSPanel` above the menu bar
  (`OverlayWindow`), sized to the overlay only: a strip around the notch or island that
  grows while the panel is expanded.
- `NotchGeometry` finds the hardware notch from the screen's safe area, or defines a
  virtual island for displays without one. `NotchShapeBuilder` turns the shape
  parameters into a `CGPath` drawn by a shape layer.
- `OverlayView` positions the circles, swallows clicks that land on the overlay and
  lets everything else through. Clicking the gauge expands the shape into a panel
  hosting `StatsPanelView`.
- `StatsPanelView` draws the tab row and builds each tab's view on first use. The
  camera pipeline is released whenever the panel closes.
- Settings are one `Codable` struct (`AppSettings`) stored as JSON in `UserDefaults`
  under `NotchOrbit.settings`. Stored JSON is merged over the current defaults, so
  settings saved by an older version keep loading. Writes are coalesced.

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
  FaceTransform.swift          Face Transform engine: finds / launches the deep-facial server, identities, enrolment, live WebSocket session, camera frames out and transformed frames back
  FacePanelViews.swift         Camera tab face UI: output feed, consent card, control row (Transform, face picker, Enroll, more) and the Enroll Face window
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

Face Transform adds nothing while it is off. With the feature on and idle, the engine
holds no camera or GPU resources; during a session it costs about 7 MB in NotchOrbit.
The face server is a separate process and holds about 1 GB of models while it runs.

## Implementation notes

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
- Face Transform talks to the deep-facial server over `http://127.0.0.1:<port>` (health,
  identities) and `ws://127.0.0.1:<port>/ws/live`: a JSON `start` message carrying the
  identity, the performer's consent for that session, options and the virtual-camera
  request, then camera frames as JPEG (at most two in flight, 30 a second) and replies of
  `[u32 header length][JSON stats][JPEG]`. The server refuses a session without the
  consent flag, and NotchOrbit only sends it from the confirmation card. The transformed
  feed is shown unmirrored so the badge reads correctly. While a session runs the engine
  owns the camera; the tab's own session is stopped and its preview layer shows the
  engine's session as the input feed (unmirrored, to line up with the output). A server NotchOrbit
  launched logs to `~/Library/Logs/NotchOrbit/face-server.log`. `Info.plist` allows
  cleartext to local addresses only (`NSAllowsLocalNetworking`).
- Weather: one request to `api.open-meteo.com` per refresh (coordinates only; no account,
  no tracking) and `geocoding-api.open-meteo.com` for the city search. The last reading is
  cached for up to three hours so the circle has something to show right after launch.
- Stats readings: CPU is the busy share of all cores since the previous sample; memory
  matches Activity Monitor's "Memory Used" (app + wired + compressed); GPU comes from the
  graphics driver's `Device Utilization %` counter in the IO registry; disk is the used
  share of the startup volume; battery is the internal battery's charge (hidden on
  desktops); apps counts applications that show in the Dock / ⌘-Tab switcher, and the
  ring is full at 20 of them.

## Debugging

- `NOTCHORBIT_DEBUG=1` logs geometry, clicks and stats samples to stderr.
- `NOTCHORBIT_DEBUG_TAB=stats|weather|mic|camera` opens the panel on that tab after launch.
- Run the executable inside the bundle to see the log:
  `NOTCHORBIT_DEBUG=1 build/NotchOrbit.app/Contents/MacOS/NotchOrbit`
- A face server launched by NotchOrbit logs to `~/Library/Logs/NotchOrbit/face-server.log`.
- `footprint -p $(pgrep -x NotchOrbit)` and `heap -s $(pgrep -x NotchOrbit)` show where memory goes.
