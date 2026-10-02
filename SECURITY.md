# Security and privacy

## What Fader can access

| Permission | Why | When |
|---|---|---|
| System Audio Recording | Process taps read each app's audio so Fader can change its volume and show its level. | Only for apps you change, plus all playing apps while the panel is open (meters). |
| Microphone | The microphone level meter. | Only while the panel is open, never for Bluetooth microphones. |

Audio is processed in memory, in real time, and then discarded. Nothing is recorded, stored, or sent anywhere: **Fader makes no network requests at all** (no updates check, no analytics, no crash reporting). You can confirm with Little Snitch or by searching the source for networking APIs.

## Other system changes

- **Dictation key remap.** By default the Dictation key (F5) is mapped to F18 with `hidutil` so it can open the panel. Turn it off in the gear menu; the mapping is removed immediately and is also cleared on reboot.
- **Launch at login** is enabled on first run from /Applications through `SMAppService`; turn it off in the gear menu or in System Settings > General > Login Items.
- When Fader quits or crashes, macOS destroys its taps and every app's audio returns to normal immediately.

## Reporting a vulnerability

Please don't open a public issue. Use GitHub's private vulnerability reporting on this repository (Security > Report a vulnerability).
