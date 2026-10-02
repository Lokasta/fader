# Contributing to Lokasta's Fader

Thanks for helping out! Fader is small on purpose, so most contributions are a focused fix or feature plus a test. Bug reports and ideas are just as welcome: open an [issue](https://github.com/Lokasta/fader/issues/new/choose).

Security problems go through private reporting instead, see [SECURITY.md](SECURITY.md).

## Setup

You need **Xcode 26** or newer (the app runs on macOS 15+, the Control Center widget needs macOS 26) and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen
git clone https://github.com/Lokasta/fader && cd fader
xcodegen generate        # Fader.xcodeproj is generated from project.yml and never committed
```

Builds are ad-hoc signed out of the box, no certificate needed. macOS asks for permissions again after each rebuild because the signature changes. To sign with your own identity, see `Config/Signing.xcconfig`.

## Build, test, run

```bash
xcodebuild -project Fader.xcodeproj -scheme Fader -derivedDataPath build test   # build + unit tests
./scripts/install.sh                                                            # Release build into /Applications, relaunch
build/Build/Products/Debug/Fader.app/Contents/MacOS/Fader --snapshot panel.png  # render the panel, no audio touched
```

Changed `project.yml` or added a file? Run `xcodegen generate` again.

## Verifying audio changes without hearing them

Tests and CI can't listen, and neither can a coding agent. [AGENTS.md](AGENTS.md#how-to-verify-your-change) lists what to use instead: unit tests for the renderer and meter math, the `com.lokasta.fader` logs, `--snapshot`, `say`/`afplay` to generate sound, and a quick CPU check.

## Safety rules

Fader sits in the audio path of every app, so a mistake can silence someone's sound or wreck their mic. Read the [rules in AGENTS.md](AGENTS.md#rules-hard-won-keep-them) before touching `Fader/Audio/` or `Fader/Model/Mixer.swift`. The short version:

- Never create a tap without audio capture permission.
- Only `MicMeter` opens the microphone, only while the panel is visible, never on Bluetooth inputs.
- IO blocks are real-time: no allocation, locks, logging or `print`.
- No network access, ever.
- Declare entitlements in `project.yml`, not in the `.entitlements` files.

## Pull request checklist

- [ ] `xcodebuild ... test` passes locally (CI runs it on every PR too).
- [ ] User-visible changes have an entry under `## Unreleased` in [CHANGELOG.md](CHANGELOG.md).
- [ ] New UI strings are in `Fader/Localizable.xcstrings` with a pt-BR translation (use `String(localized:)` for strings in variables or ternaries).
- [ ] No em dash characters (U+2014) anywhere. CI fails on them; a comma almost always works.
- [ ] Audio changes were verified as described above, and the PR says how.

## Commit style

Imperative subject line ("Add mute shortcut", not "Added..."), and a short body explaining *why* when it isn't obvious. Keep unrelated changes in separate commits.

## Releases

Releases are cut by the maintainer with `scripts/release.sh`, which builds, signs with Developer ID, notarizes and publishes the DMG. Contributors don't need to bump versions or touch the release script.
