# Changelog

## 2026-10-02 -- 1.6.0

**Open source prep.**

- Name: **Lokasta's Fader** (display name; the bundle stays `Fader.app`, `com.lokasta.fader`).
- English UI by default with a Brazilian Portuguese translation (`Localizable.xcstrings`, `InfoPlist.xcstrings`, widget catalog). Follows the system language.
- Signing moved to `Config/Signing.xcconfig`: ad-hoc for contributors, `Config/Local.xcconfig` (gitignored) for the maintainer's Developer ID.
- `scripts/release.sh`: Release build, DMG, Developer ID signature, notarization and stapling; fails fast without notary credentials.
- Docs: English README, `AGENTS.md` (architecture, safety rules, how to verify without hearing; `CLAUDE.md` imports it), `SECURITY.md`, MIT `LICENSE`.
- **Fix**: other running copies of Fader no longer show up in the app list.

## 2026-10-02 -- 1.5.1

**Performance**: lighter idle loop. Measured 7.2% CPU with the panel open before, 0.56% with the panel closed and one app being mixed after.

- PID and bundle ID of each Core Audio process object are read once and cached; only "is playing" is polled.
- Device lists are cached and re-read only when Core Audio reports a device change; the per-second refresh reads just volume and mute.
- Bursts of Core Audio notifications are folded into one refresh (100 ms).
- Meter bars no longer run a SwiftUI animation on every 30 Hz update.

## 2026-10-02 -- 1.5.0

**Performance / Fix**: stress-tested with 20 apps playing at once.

- New `MeterHub`: meters for every unmixed app share ONE aggregate device and IO proc instead of one per app. With 20 apps and the panel open, Fader went from ~23% to ~5% CPU (one HAL IO thread instead of 20). Rebuilding it is silent because meter taps never change the audio.
- `AppTap` is mixing-only again; `setStreamUsage` is shared by both.
- The app list caps at ~440 pt and scrolls (verified with 20 apps).
- macOS services get readable names via Core Audio's process bundle ID (`proc_name` is refused for root daemons): `systemsoundserverd` now shows as "Sons do sistema" instead of "Processo 40304".
- `--snapshot` runs never create taps (`Mixer.touchesAudio`).

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
