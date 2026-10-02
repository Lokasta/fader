# Fader

Menu bar app (macOS 15+, Swift/SwiftUI) for per-app volume using Core Audio Process Taps. No drivers. UI text is Brazilian Portuguese.

## Layout

- `project.yml`: XcodeGen spec. `Fader.xcodeproj` is generated and gitignored; run `xcodegen generate` after adding/removing files.
- `Fader/Audio/CoreAudio.swift`: typed property helpers on `AudioObjectID`, `AudioDevices` (device list, default device, volume, mute) and `AudioDirection` (output/input).
- `Fader/Audio/AppTap.swift`: one tap per app: `CATapDescription` (mutedWhenTapped, private) + private aggregate device (output device as main sub-device) + block IO proc. Disables the output device's own input streams via `kAudioDevicePropertyIOProcStreamUsage` so headsets never switch to call mode.
- `Fader/Audio/GainRenderer.swift`: real-time render code. `RenderContext` holds atomics shared with the UI thread. No allocation, locks or logging in the IO path.
- `Fader/Audio/AudioProcesses.swift`: Core Audio process list and app attribution via `responsibility_get_pid_responsible_for_pid` (dlsym).
- `Fader/Audio/AudioCapturePermission.swift`: TCC preflight/request for `kTCCServiceAudioCapture` (private TCC framework, dlopen).
- `Fader/Model/Mixer.swift`: `@MainActor` model. 1 s refresh loop plus Core Audio listeners; `reconcileTap` decides when taps exist. `DeviceState` covers output and microphone.
- `Fader/Model/VolumeStore.swift`: per-bundle-ID volume/mute in UserDefaults.
- `Fader/UI/`: SwiftUI views. `Snapshot.swift` implements `--snapshot <png>`. `FloatingPanel.swift` is the Control Center-style panel opened by `fader://panel`.
- `FaderControls/`: WidgetKit extension (macOS 26+) with one `ControlWidgetButton` that opens `fader://panel` via `OpenURLIntent`. Must stay sandboxed; the entitlement is declared in `project.yml` because XcodeGen rewrites the `.entitlements` file.
- `Fader/UI/GlobalHotKey.swift`: ⌃⌥V via Carbon `RegisterEventHotKey`. Reopening the app (`applicationShouldHandleReopen`) also shows the panel.
- `fader://` URLs are handled with a raw Apple Event handler in `AppDelegate` (SwiftUI swallows them otherwise).
- `scripts/install.sh`: Release build, install to /Applications, relaunch. `scripts/make-icon.swift`: draws the app icon.

## Rules

- Never open or capture an input stream. Microphone support is limited to default-device selection and system input volume/mute.
- Never create a tap without audio capture permission: a tap without permission mutes the app and delivers silence.
- Apps at exactly 100% and not muted must not be tapped (a tap is kept only while still playing, to avoid a glitch).
- `FloatingPanel` owns its frame (`sizingOptions = []`) and refits on model changes, debounced. Resizing from a window resize notification caused an AppKit layout-loop crash.
- The panel ignores losing key focus for 1.5 s after showing (the launcher steals focus back); outside clicks close it via a global mouse monitor.
- Keep the IO block allocation-free. Don't iterate array literals or log there.
- Swift language mode 5 (see project.yml). Signing: Developer ID Application, team N45547YJ4V.
- The shell's `log` is a zsh builtin: use `/usr/bin/log show --predicate 'subsystem == "com.lokasta.fader"' --info`.

## Commands

```bash
./scripts/install.sh
xcodebuild -project Fader.xcodeproj -scheme Fader -derivedDataPath build test
```
