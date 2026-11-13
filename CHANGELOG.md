# Changelog

## 2.0.0 — 2026-11-13

- Face Transform (Settings › Camera & Face Swap, off by default): the Camera tab can show
  you as an enrolled identity, using the local deep-facial server. Input and output
  feeds side by side with a control row (Transform, face picker, Enroll Face, more),
  per-session consent card, native enrolment window with the consent attestations, live
  option changes, snapshot of the transformed frame,
  optional output to the server's virtual camera with "Keep running", a Stop item in the
  menu-bar menu, and server start / stop from NotchOrbit. The server's AI TRANSFORMED
  badge is on every transformed frame.

- The version is shown at the top of the menu-bar menu (and in the status item's
  tooltip), as well as in Settings.
- `build.sh` uses an installed Xcode when the Command Line Tools are selected (SwiftUI's
  macros need Xcode's compiler plugin).
- Screenshots of Face Transform (Camera tab, Settings page, Enroll Face window) rendered
  by `Tools/render-screenshots.swift` with stand-in feeds.
- Open-source release: MIT licence, restructured README, documentation under `docs/`,
  contributing and security notes, and a GitHub Actions build.
- Settings: one page per feature. The Mic tab's options moved from System Stats to a
  new Microphone page, the Camera tab's options joined Face Transform on Camera & Face
  Swap, and the capture folder moved to General. The descriptive "Expanded panel" rows
  and the duplicate session row were removed. The voice engine and audio device lists
  are no longer loaded just by opening the System Stats page.
- Face Transform memory: the camera session and video output only exist during a
  session, frames are encoded with VideoToolbox + ImageIO instead of Core Image, the
  output feed is decoded at display size, and frames no longer queue up for the main
  thread (one slot, newest wins). A live session costs about 7 MB in the engine, down
  from about 15 MB, and creating the engine costs nothing measurable.

## 1.3.0 — 2026-11-09

Performance and footprint release. No new features; behaviour is unchanged unless
noted.

### Measured (14" MacBook Pro + two external displays, stats and weather on, headless)

| | 1.2.0 | 1.3.0 |
|---|---|---|
| Footprint, idle, Use as Mic off | 21 MB | 19 MB |
| Footprint, panel open on Stats tab | 30 MB | 26 MB |
| Idle CPU after 40 s (Use as Mic on) | 3.5 % | 0.1 % |
| Overlay window surface, built-in display | 1728 × 360 pt | 548 × 52 pt |
| Overlay window surface, each external display | 2560 × 360 pt | 548 × 78 pt |
| App bundle | 3.6 MB | 2.7 MB |
| DMG | 5.3 MB | 2.1 MB |

With "Use as Mic" and echo cancellation on, Apple's voice-processing unit adds about
45 MB of its own (a noise-suppression model) in either version; that is the largest
single cost of the app and is outside NotchOrbit's code.

### Memory

- Overlay windows now cover only the overlay (a strip around the notch or island),
  growing while the panel is expanded, instead of the full display width at the
  panel's height; the overlay shape layer is sized to the shape rather than the window.
- The expanded panel and its tabs are built on first use. The camera tab's capture
  session, preview layer and audio engine are released whenever the panel closes.
- The Settings window (SwiftUI) is released when closed instead of staying resident.
- Core Location is only started by weather mode with "Current location" or by the
  Settings privacy rows; a chosen city never loads it.
- The audio HAL and voice engine are only touched by features that use them. Launch
  and quit no longer query audio devices unless "Use as Mic" has been used before.
- The unused animated-image playback code was removed.

### CPU and energy

- Stats sampling pauses while the displays sleep.
- The GPU reading reads one IO registry property per accelerator (matched once)
  instead of copying every property of every accelerator every tick.
- Settings writes are coalesced (one write per half second of changes instead of one
  per slider tick); pending changes are flushed on quit.
- Panel icons are rasterised once and cached; they were re-rendered from their vector
  form on every redraw. The Mic tab only redraws its header for level-meter ticks,
  and the Camera tab's level meter updates at most 30 times a second.
- The debug flag is read once instead of copying the process environment on every
  mouse move and stats tick.
- The webcam preview runs at 720p rather than the camera's native resolution.

### Storage

- App icon: 1.5 MB → 0.77 MB. The generator now renders in 16-bit and converts to
  8-bit without the gradient dithering that bloated the PNG layers.
- DMG background: the two PNGs (1.5 MB, with the 2x copy never used by Finder) are
  replaced by one 0.37 MB HiDPI TIFF that is sharp on Retina displays.
- Release builds use `-Osize` and are fully stripped (universal binary about 11%
  smaller); `ARCHS=arm64 ./build.sh` gives a single-architecture build at half the
  size. The DMG is LZMA-compressed. `./build.sh clean` removes build products.

## 1.2.0

- Mic tab: voice effects, playthrough, recording, "Use as Mic" via a loopback driver
  with echo cancellation.
- Weather tab and full-screen weather scenes.
