# Changelog

## 2026-10-02 -- 1.4.0

**Feature**: live level meters.

- A level bar under every app slider, the output slider (loudest app) and the microphone slider. dB scale, instant attack, smooth release, green/yellow/red.
- App meters show what you hear (after that app's volume). Apps at 100% get a meter-only tap (`muteBehavior = .unmuted`, nothing re-rendered) while a panel is visible, so their audio path is unchanged.
- Switching an app from metering to mixing builds the new tap before dropping the old one, so audio never gaps.
- Microphone meter (`MicMeter`) opens the default input only while a panel is visible and never on Bluetooth inputs (would force headsets into call mode). Adds `NSMicrophoneUsageDescription` and the `com.apple.security.device.audio-input` entitlement.
- Metering starts and stops from window occlusion (`WindowVisibility`), for both the menu bar popover and the floating panel.
- Removed the "audio flowing" log, which drained the peaks the meters now read. 15 unit tests.

## 2026-10-02 -- 1.3.0

**Feature**: the Dictation key (F5) opens the panel.

- `DictationKeyRemap` maps HID consumer usage 0xCF (Dictation) to F18 with `hidutil` user key mappings, reapplied at launch and preserving other mappings. Fader listens for F18.
- Gear menu option "Tecla de Ditado (F5) abre o Fader" (on by default); turning it off restores Dictation immediately.
- `GlobalHotKey` now supports several hot keys (each handler checks its own ID).

## 2026-10-02 -- 1.2.0

**Feature**: more ways to open the panel when the menu bar is crowded.

- Global shortcut ⌃⌥V toggles the panel from any app (Carbon hot key, no Accessibility permission).
- Opening Fader again (Spotlight, Finder) shows the panel.
- **Fix**: the panel no longer closes right after opening when the launching app (Spotlight, a terminal) takes focus back.

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
