# Face Transform

Face Transform shows you, in the Camera tab and optionally on video calls, with the
face of an enrolled person who has agreed to it. Your head pose, expression, gaze and
lip movement are kept. It is off by default.

NotchOrbit does not contain any face models. It is a client of a **separate face
server** that runs on your own Mac and listens on `127.0.0.1` only. Camera frames never
leave the machine.

## Rules for using it

- Enrol a face only with that person's permission, and transform only people who agree
  to be transformed. NotchOrbit asks for both attestations at enrolment and asks the
  person on camera again before every session.
- Do not use it to impersonate anyone, to pass identity verification or liveness
  checks, or to present transformed video as authentic footage.
- On a call, tell the other participants. Every transformed frame carries an
  **AI TRANSFORMED** badge drawn by the server; there is no setting that removes it,
  and it is an aid to disclosure, not a substitute for saying so.
- The default face models are under a non-commercial research licence (below).

## What you need

| | |
|---|---|
| The face server | The companion `deep-facial` project: a FastAPI server using ONNX Runtime with Core ML. It is not part of this repository. |
| Mac | Apple silicon recommended (about 11 fps on an M1 Pro; CPU-only is about 1 fps) |
| Python | 3.11 or later (3.12 recommended), with [`uv`](https://docs.astral.sh/uv/) or pip |
| Disk | About 830 MB for the models, plus the Python environment |
| Memory | About 1 GB while the server runs |
| `ffmpeg` | Optional; only the server's own video-file jobs use it |
| OBS Studio 30+ | Optional; provides the virtual camera for video calls |

## Setting up the server

In the face server's folder:

```bash
make setup     # creates .venv and installs the requirements
make models    # downloads buffalo_l and inswapper_128 (about 830 MB), verifies checksums
make test      # optional: the server's own test suite
```

You do not need to start it yourself. To check it by hand: `make run`, then open
<http://127.0.0.1:8787>; the status dot turns green when the models are loaded
(5 to 20 seconds on first start while Core ML compiles them).

## Connecting NotchOrbit

1. Settings › **Camera & Face Swap** › switch on **Face swap in the Camera tab**.
2. **deep-facial folder** › *Choose…* and pick the server's folder (the one containing
   `server/` and `.venv/`).
3. The **Server** row shows the state. If a server is already running on the port it is
   used as it is. Otherwise NotchOrbit starts one when a session, the face picker or
   the Start button needs it, and stops it five minutes after the last session and when
   NotchOrbit quits. A server you started yourself is never stopped by NotchOrbit.

System Stats mode must be on, because the Camera tab lives in the expanded panel.

## Using it

Open the panel and choose the Camera tab. With the feature on it shows two feeds,
**INPUT** (your camera) and **OUTPUT** (the transformed feed), and a row of controls
below them.

| Control | What it does |
|---|---|
| **Transform** | Shows a confirmation in the output pane; "I Agree · Start" begins the session. Becomes **Stop** while running. |
| **Face picker** | A compact scrolling list of enrolled faces. Switching during a session takes effect immediately. |
| **Enroll Face** | Opens the enrolment window (below). |
| **⋯** | Send output to the virtual camera, keep running after the panel closes, open the server's web app, open Settings. |
| Status text | Frame rate, "transforming" or "no face", and whether the virtual camera is live. |
| Shutter | During a session saves the output frame, badge included. |

When no face is found, or it is too small or uncertain, the output is the untouched
camera frame with no badge, and the status says "no face".

### Enrolling a face

Enroll Face asks for a name, photos or short clips of one person, who is attesting, and
two statements: that the person in the photos gave permission, and that everyone who
will be transformed into that face agrees. Both are required and are stored with the
face, with the attesting name and time.

For a good likeness use 30 to 100 sharp, well-lit samples covering front, three-quarter
and profile views. Each sample is quality-checked (face size, sharpness, detector
confidence, and whether it matches the others); the result says how many were accepted
and why the rest were not.

Faces are stored encrypted by the server in its `data/` folder. Deleting a face, and
the server's per-sample diagnostics, are in its web app (⋯ › Manage Faces in the Web App…).

### Video calls

1. Install OBS Studio 30 or later, start it once and click *Start Virtual Camera* so
   macOS installs its camera extension (System Settings › General › Login Items &
   Extensions › Camera Extensions). OBS does not need to stay open.
2. In NotchOrbit turn on **Send the transformed feed to the virtual camera** (Settings,
   or the ⋯ menu), then start a session.
3. In FaceTime, Teams, Zoom or Meet pick **OBS Virtual Camera** as the camera.

*When no face is found* decides what the call sees in that case: the last transformed
frame (default, so your own face is never sent) or the original camera.

**Keep running after the panel closes** leaves the session, and the camera, on once the
panel collapses. Stop it with the Stop button in the Camera tab or with *Stop Face
Transform* in the menu-bar menu. Without it, the session ends when the panel closes.

## Settings reference

| Setting | Default | Meaning |
|---|---|---|
| Face swap in the Camera tab | off | Shows the output feed and the controls |
| deep-facial folder | none | Where to launch the server from |
| Start the server when a session needs it | on | Otherwise only an already running server is used |
| Port | 8787 | Port on 127.0.0.1 |
| Appear as | none | The enrolled face |
| Profile | Fast | Detector size and the width of frames sent: 640, 960 or 1280 px |
| Match skin colour to the camera | on | Colour transfer inside the face mask |
| Stabilise the face between frames | on | Smooths landmarks; less jitter |
| Keep my own mouth | off | Sharper lip-sync, weaker likeness |
| Swap every second frame | off | About twice the frame rate; expression lags one frame |
| Send the transformed feed to the virtual camera | off | Output to OBS Virtual Camera |
| When no face is found | Hold | What the virtual camera shows meanwhile |
| Keep running after the panel closes | off | Only applies with the virtual camera on |

## How it works

```
Camera ─► FaceTransform (NotchOrbit) ─ JPEG over ws://127.0.0.1:<port>/ws/live ─► face server
                    ▲                                                              detect → track → align → swap
                    └────────── [header][JPEG] transformed frame ◄─────────────── composite → badge
                                                                                        │ (opt-in)
                                                                                        ▼
                                                                              OBS Virtual Camera → call app
```

- `GET /api/health` reports whether the models are loaded and whether the virtual
  camera is available; `GET /api/identities` lists faces; `POST /api/identities`
  (multipart) enrols one.
- A session opens the WebSocket and sends
  `{"type":"start","identity_id":…,"performer_consent":true,"options":{…},"vcam":{…}}`.
  The server refuses the session without the consent flag; NotchOrbit only sends it
  from the confirmation card.
- Camera frames go out as JPEG, at most two in flight and thirty a second. Each reply
  is a 4-byte big-endian header length, a JSON header with timings and state, then the
  JPEG. Control messages change options, the face or the virtual camera mid-session.
- During a session the engine owns the camera and the Camera tab previews the engine's
  capture session as the input feed. Both feeds are shown unmirrored so the badge reads
  correctly and the two line up.
- NotchOrbit allows cleartext connections to local addresses only
  (`NSAllowsLocalNetworking`). Nothing is sent anywhere else.

Any server that implements these endpoints can stand in for the reference one. The
client is `Sources/NotchOrbit/FaceTransform.swift`; the interface is in
`Sources/NotchOrbit/FacePanelViews.swift`.

## Privacy

| Data | Where it lives |
|---|---|
| Camera frames | In memory only, in NotchOrbit and the server, for the life of a frame |
| Enrolled faces (an embedding, a thumbnail, the consent record) | Encrypted in the server's `data/identities/`; the key is `data/identity.key` |
| Photos you take with the shutter | Your capture folder; transformed ones have "(AI transformed)" in the name |
| Server log | `~/Library/Logs/NotchOrbit/face-server.log`; no images |

Deleting the server's `data/identity.key` makes every enrolled face unreadable.

## Model licences

The reference server uses InsightFace's `buffalo_l` and `inswapper_128` models, which
are released for **non-commercial research use**. Commercial use needs a licence from
InsightFace or different models. NotchOrbit's MIT licence does not change that.

## Troubleshooting

| Problem | What to check |
|---|---|
| "Choose the deep-facial folder…" | Pick the folder in Settings › Camera & Face Swap |
| "No Python environment…" | Run `make setup` and `make models` in the server's folder |
| Server stops while starting | Read `~/Library/Logs/NotchOrbit/face-server.log`; a missing model file or a port in use are the usual causes |
| Stays on "Loading the face models…" | First start compiles the Core ML graphs; allow up to a minute |
| Output shows your own face, status "no face" | Face too small, turned away or badly lit; move closer |
| Low frame rate | Use the Fast profile, turn on Swap every second frame, make sure the server reports CoreML, not CPU |
| Virtual camera "Unavailable" or "Retrying" | Install OBS 30+, start its virtual camera once, allow the camera extension; quit other apps holding the device |
| The call shows a dark "waiting for a face" card | No frame has been transformed yet; face the camera |
| Port already used by something else | Change the port in Settings (and start the server with `RTIT_PORT` if you run it yourself) |
