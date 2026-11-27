# Security

## Reporting a vulnerability

Please do not open a public issue for a security problem. Use GitHub's private
reporting instead: the repository's **Security** tab › **Report a vulnerability**.
Include the version, what the issue allows and how to reproduce it. You will get a reply
as soon as the report has been looked at.

## What is in scope

- The app talking to anything other than the documented endpoints: Open-Meteo for
  weather, the BlackHole download (checksum verified) and the face server on `127.0.0.1`.
- Camera, microphone, screen capture or system-audio capture running when the user did
  not ask for it (Screen Ripple must do neither while it is switched off, and must not
  capture the screen while the Mac is locked).
- Ways to start a Face Transform session, or enrol a face, without the confirmations.
- Problems in how settings or captures are written to disk.

## Notes

- NotchOrbit is not sandboxed. It needs to place a window above the menu bar, manage
  audio devices and launch the face server.
- Screen Ripple's lock-screen ripple uses private window-server (SkyLight) calls to place
  its click-through window above the lock screen. The window takes no input and shows
  only light.
- Release builds signed with a Developer ID use the hardened runtime with only the
  camera and microphone entitlements.
- The face server is a separate project; report problems in it to that project.
