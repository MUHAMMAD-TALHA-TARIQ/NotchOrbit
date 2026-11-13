# Features

Everything NotchOrbit does, feature by feature. Settings are in the menu-bar menu ›
Settings…, one sidebar page per feature.

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
- **Face Transform** (off by default; Settings › Camera & Face Swap) – the Camera tab can show
  you as an enrolled, consenting identity. NotchOrbit is a client of the separate
  deep-facial project (see [FACE_TRANSFORM.md](FACE_TRANSFORM.md)): a Python server on this Mac (127.0.0.1 only)
  that detects, swaps and composites the face and burns an **AI TRANSFORMED** badge into
  every transformed frame. Point Settings at the project folder and NotchOrbit starts the
  server when a session needs it (a server already running on the port is used as is) and
  stops it five minutes after the last session and on quit. The Camera tab then shows two
  feeds side by side, **input** (the camera) and **output** (the transformed feed), with
  a control row under them: **Transform** asks the person on camera to agree to each
  session and starts it (it becomes Stop), a face picker lists the enrolled faces and
  can switch during a session, **Enroll Face** opens a window that takes a name, photos
  or clips and the two consent attestations, and a ⋯ menu holds the virtual-camera
  options. The status at the end of the row shows frame rate and whether a face is being
  transformed. The shutter saves the output frame, badge included.
  **Send to virtual camera** has the server
  feed its output into OBS Virtual Camera for FaceTime, Teams, Zoom or Meet, and **Keep
  running** leaves that session on after the panel closes (stop it from the Stop button
  or the menu-bar menu). The server records the consent of the face's owner and the
  performers with each enrolled face; deleting faces is done in its web app. Use it only with those
  permissions, never against identity or liveness checks, and tell the people you are
  talking to. The face models are under a non-commercial research licence (see the
  deep-facial README).
- **Settings window** – sidebar layout (Notch Shape, Circles, Dynamic Island, System
  Stats, Weather, Microphone, Camera & Face Swap, General; each feature's options live on
  its own page, and the shared capture folder is under General) with live 1:1 previews, camera/microphone permission status, a
  reset-to-defaults action and version info.
- Clicks on the overlay itself (the notch / island shape, the circles, the expanded panel)
  are swallowed so they never reach the app behind; everywhere else the menu bar and
  desktop get clicks as usual.
- Works over full-screen apps and on every Space; follows display changes.
- Menu-bar only (no Dock icon), optional launch at login, settings persist.
