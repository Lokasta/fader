# AGENTS.md

Guide for AI coding agents (Claude Code, Codex, Cursor, Copilot...) and humans working on **Lokasta's Fader**: a macOS menu bar app for per-app volume built on Core Audio Process Taps. No kernel extension, no virtual audio driver, no network access.

Read this whole file before changing audio code. Most rules below exist because breaking them makes someone's audio go silent, glitch, or makes their microphone misbehave.

## Quick start

```bash
brew install xcodegen
xcodegen generate                                   # Fader.xcodeproj is generated, never committed
xcodebuild -project Fader.xcodeproj -scheme Fader -derivedDataPath build test
./scripts/install.sh                                # Release build -> /Applications/Fader.app, relaunch
```

Requirements: macOS 15+ to run (Control Center control needs macOS 26), Xcode 26+ to build.

## How to verify your change

You can't hear audio, so verify with these instead:

- **Unit tests** cover the real-time renderer, volume store and meter math: `xcodebuild ... test`.
- **Logs** (the shell's `log` is a zsh builtin, use the full path):
  `/usr/bin/log show --last 5m --predicate 'subsystem == "com.lokasta.fader"' --info`
  Categories: `mixer` (tap decisions), `meters`, `panel`, `mic`, `keys`, `tap`, `chrome` (automation failures and response counts; no tab titles or URLs).
- **Snapshot** the real panel to a PNG without touching audio (a `--snapshot` run never creates taps):
  `build/Build/Products/Debug/Fader.app/Contents/MacOS/Fader --snapshot out.png -AppleLanguages '(en)'`
- **Chrome fixture:** add `--snapshot-chrome-tabs` for deterministic tab rows. Snapshot and XCTest hosts never automate the live browser, remap keys or open the microphone.
- **Chrome player checks:** `node scripts/test-chrome-media.cjs` with Playwright installed, or `FADER_TEST_CHROME=1 node scripts/test-chrome-media.cjs` with an installed Chrome. These use an isolated, muted browser with offline fixtures; CI installs the pinned tools separately from the repo.
- **Generate sound** to test with: `say "testing"` or `afplay /System/Library/Sounds/Submarine.aiff`. Both are attributed to the terminal app that launched them.
- **CPU**: `ps -o time= -p $(pgrep -x Fader)` before and after 30 s. Idle with the panel closed should stay under ~1%.

## Architecture

| Path | What it does |
|---|---|
| `Fader/Audio/CoreAudio.swift` | Typed property helpers on `AudioObjectID`; `AudioDevices` (lists, default device, volume, mute); `AudioDirection`. |
| `Fader/Audio/AppTap.swift` | **Mixing** tap for one app: `CATapDescription` (`mutedWhenTapped`, private) + private aggregate device (output device as main sub-device) + block IO proc that replays the audio at our gain. |
| `Fader/Audio/GainRenderer.swift` | Real-time render code. `RenderContext` holds atomics shared with the UI. Gain ramps per buffer, soft limiter above 100%. |
| `Fader/Audio/MeterHub.swift` | **Metering** for every unmixed app through ONE aggregate (unmuted taps, one IO proc). Also `setStreamUsage`. |
| `Fader/Audio/MicMeter.swift` | Mic level meter + `PeakBox` (lock-free peak shared with audio threads). |
| `Fader/Audio/AudioProcesses.swift` | Core Audio process list (PID/bundle ID cached per object) and app attribution via `responsibility_get_pid_responsible_for_pid`. Friendly names for macOS audio daemons. |
| `Fader/Audio/AudioCapturePermission.swift` | TCC preflight/request for `kTCCServiceAudioCapture` (private TCC framework via dlopen). |
| `Fader/Model/Mixer.swift` | `@MainActor` model: 1 s refresh + Core Audio listeners (bursts coalesced), `reconcileTap`, metering lifecycle, `DeviceState` for output and mic. |
| `Fader/Model/LevelMeters.swift` | dB normalization and smoothing; separate `ObservableObject` so 30 Hz updates don't redraw the whole panel. |
| `Fader/Model/VolumeStore.swift` | Per-bundle-ID volume and mute in UserDefaults. |
| `Fader/Browser/ChromeAutomation.swift` | Opt-in Automation permission, tab metadata enumeration, bounded per-tab Apple Events and timeout backoff. Runs off the UI thread. |
| `Fader/Browser/ChromeMedia.js` | Relative gain for HTML audio/video, original player settings, document identity and restoration watchdog. Bundled as a resource. |
| `Fader/Model/ChromeTabs.swift` | Playing-tab discovery, pending controls, in-memory state and restore-on-disable/quit. |
| `Fader/UI/` | SwiftUI views; `FloatingPanel` (Control Center-style panel), `GlobalHotKey` (⌃⌥V, F18), `DictationKeyRemap` (F5 to F18 via `hidutil`), `WindowVisibility`, `Snapshot`. |
| `FaderControls/` | WidgetKit extension (macOS 26+): one `ControlWidgetButton` that opens `fader://panel`. |
| `Config/Signing.xcconfig` | Ad-hoc signing by default; `Config/Local.xcconfig` (gitignored) overrides it. |
| `scripts/` | `install.sh`, `release.sh` (signed + notarized DMG), `make-icon.swift`. |

### Lifecycle of a tap

- App at 100% and panel closed: **nothing**. Its audio goes through macOS untouched.
- App not at 100% (or muted): a **mixing** `AppTap`. Kept while it plays even back at 100% (tearing it down mid-song glitches), dropped once quiet.
- Panel visible: every playing app without a mixing tap is **metered** through `MeterHub`. Meter taps are unmuted and never change what you hear, so rebuilding the hub is silent.
- Switching an app from metered to mixed creates the mixing tap first; audio never gaps.

## Rules (hard-won, keep them)

1. **Never create a tap without audio capture permission.** A `mutedWhenTapped` tap without permission mutes the app and delivers silence.
2. **The microphone is opened only by `MicMeter`**, only while a panel is visible (`WindowVisibility` → `beginMetering`/`endMetering`), and **never on Bluetooth inputs** (it forces headsets into low-quality call mode). Nothing else may open an input stream.
3. **Aggregates include the output device's own inputs** (an AirPods mic). Always disable them with `setStreamUsage`, and read tap buffers after `inputBufferOffset`.
4. **IO blocks are real-time:** no allocation, locks, logging, Swift array literals or `print`. Share state through atomics (`PeakBox`, `RenderContext`).
5. **One aggregate for all meters.** One aggregate per meter cost ~23% CPU with 20 apps; the hub costs ~5%.
6. **Don't tap Fader itself.** Its own output is a Core Audio process; `AudioProcesses.list` filters every running copy.
7. **`FloatingPanel` owns its frame** (`sizingOptions = []`) and refits on model changes, debounced. Resizing from a window-resize notification caused an AppKit layout-loop crash.
8. **The panel ignores losing focus for 1.5 s after showing** (Spotlight or a terminal steals focus back); outside clicks close it via a global mouse monitor.
9. **`fader://` URLs** go through a raw Apple Event handler in `AppDelegate`; SwiftUI swallows them in menu bar-only apps.
10. **No network access.** Fader makes no network requests and has no analytics. Keep it that way.
11. **XcodeGen rewrites `.entitlements` files**: declare entitlements in `project.yml` (`entitlements.properties`), not by editing the file.
12. **Chrome controls are optional and operate on compatible players, not Core Audio tabs.** Preserve the site's volume/mute baseline, keep Fader-muted playing tabs recoverable, never carry a control across navigation, and never let one unresponsive tab fail the entire list. Tab metadata and adjustments must stay in memory.

## Conventions

- Swift language mode 5, SwiftUI + AppKit where needed. Match the surrounding comment style: explain *why*, not what.
- UI strings are English in code and translated in `Fader/Localizable.xcstrings` (pt-BR). Use `String(localized:)` for strings in ternaries or variables (`Text(String)` is not localized), and avoid `%` in localizable keys.
- Update `CHANGELOG.md` for every user-visible change and bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.yml`.
- Commit messages: imperative subject, body explaining why.
- CI (`.github/workflows/ci.yml`) builds and runs the tests on every push and PR, and fails on any em dash (U+2014) in tracked files. [CONTRIBUTING.md](CONTRIBUTING.md) has the PR checklist.

## Private APIs in use

These keep Fader out of the Mac App Store; each is resolved at runtime and degrades gracefully if Apple removes it:

- `TCCAccessPreflight` / `TCCAccessRequest` (TCC.framework): check audio capture permission before tapping.
- `responsibility_get_pid_responsible_for_pid`: attribute helper processes (Chrome's audio service, WebKit) to their app.
