# Voice changer

The panel's Mic tab turns the microphone into a voice changer. Its settings are under
Settings › Microphone.

## What it does

A **Mic tab** beside it that turns the microphone into a
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
echo cancellation off, the microphone) is also selectable in Settings.

## Using the changed voice on calls

1. Install a loopback audio driver. Settings › Microphone shows whether one is present
   and offers a one-click install of [BlackHole 2ch](https://existential.audio/blackhole/):
   NotchOrbit downloads the publisher's package, checks its SHA-256 and opens the
   installer (macOS asks for your password; a driver cannot be installed silently).
   Loopback, VB-Cable and Soundflower are recognised too.
2. Turn on **Use as Mic** in the Mic tab, in Settings, or in the menu-bar menu.
3. FaceTime follows the system microphone automatically. In Teams, Zoom, Slack, Discord
   or WhatsApp choose **NotchOrbit Microphone** (or "Same as system").
4. Keep your speakers or headphones as the output device. Do not select the loopback
   device as an output anywhere.

Your real microphone is restored when you switch the feature off or quit. You will not
hear yourself while it is on; the people you call will.

## How it works

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

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| "Needs a virtual audio device" | No loopback driver installed; install BlackHole from Settings › Microphone |
| Callers hear an echo of themselves | Echo cancellation is off, or you are on speakers with it off; turn it on or use headphones |
| You can't hear the call | The system output is the loopback device; pick your speakers in System Settings › Sound › Output |
| Feedback squeal with Play Through | Speakers feeding the microphone; use headphones |
| Echo cancellation fails to start | Turn it off in Settings › Microphone; the plain capture path is used instead |
