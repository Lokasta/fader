# Security and privacy

## What Fader can access

| Permission | Why | When |
|---|---|---|
| System Audio Recording | Process taps read each app's audio so Fader can change its volume and show its level. | Only for apps you change, plus all playing apps while the panel is open (meters). |
| Microphone | The microphone level meter. | Only while the panel is open, never for Bluetooth microphones. |
| Automation: Google Chrome | Read tab titles, URLs and audio/video player state, and adjust compatible players through Apple Events. | Only after enabling Chrome tab controls. Discovery runs while the panel is open; tabs changed by Fader are maintained while it is closed. |

Audio is processed in memory, in real time, and then discarded. Nothing is recorded, stored, or sent anywhere: **Fader makes no network requests at all** (no updates check, no analytics, no crash reporting). You can confirm with Little Snitch or by searching the source for networking APIs.

Chrome tab controls require Chrome's **View > Developer > Allow JavaScript from Apple Events** setting. They do not capture audio or open the microphone. Tab titles, URLs and adjustments stay in memory and are not written to disk. Turning off tab controls stops discovery and attempts to restore the players Fader changed; the regular per-app controls still work.

## Other system changes

- **Dictation key remap.** By default the Dictation key (F5) is mapped to F18 with `hidutil` so it can open the panel. Turn it off in the gear menu; the mapping is removed immediately, whenever Fader quits, and on reboot.
- **Launch at login** is enabled on first run from /Applications through `SMAppService`; turn it off in the gear menu or in System Settings > General > Login Items.
- When Fader quits or crashes, macOS destroys its taps and every app's audio returns to normal immediately.
- Chrome player adjustments are restored on reset, disabling tab controls or a normal quit. If Chrome stops responding or Fader crashes, a watchdog restores them after contact is lost (normally 12 seconds; Chrome can delay background timers). Reloading or navigating resets that tab's adjustments.

## Reporting a vulnerability

Please don't open a public issue. Use GitHub's private vulnerability reporting on this repository (Security > Report a vulnerability).
