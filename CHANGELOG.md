# Changelog

## 2026-10-02 -- 1.1.0

**Feature**: Control Center control.

- New `FaderControls` WidgetKit extension: a "Fader" button for Control Center or the menu bar (macOS 26+). Third-party controls can't host sliders, so it opens the full panel.
- Floating Control Center-style panel anchored to the top-right of the active screen, opened by `fader://panel`; closes on outside click or Esc.
- **Fix**: panel crash from an AppKit layout loop (window resize feeding back into SwiftUI sizing).

## 2026-10-02 -- 1.0.0

**Feature**: first version.

- Per-app volume (0 to 200%) and mute from the menu bar, using Core Audio Process Taps. No driver or virtual device.
- Soft limiter above 100% and per-buffer gain ramps (no clicks).
- Remembers each app's volume by bundle ID and reapplies it when the app plays again.
- Helper processes grouped under their owning app (Chrome, Safari/WebKit, terminal tools).
- Output and microphone sections: pick the default device and set its system volume and mute. Fader never opens an input stream.
- Headset protection: the output device's own input streams are disabled in the IO proc, so Bluetooth headsets stay out of call mode.
- Audio capture permission check before any tap is created.
- Launch at login, enabled on first run from /Applications.
- `--snapshot <png>` debug flag, install script, generated app icon, 12 unit tests (renderer and volume store).
