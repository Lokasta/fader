## What and why

<!-- What does this change, and why is it needed? Link the issue if there is one (Fixes #123). -->

## How it was verified

<!-- Tests, logs, --snapshot, CPU check... See AGENTS.md "How to verify your change". -->

## Checklist

- [ ] `xcodebuild -project Fader.xcodeproj -scheme Fader -derivedDataPath build test` passes
- [ ] `CHANGELOG.md` has an entry under `## Unreleased` (for user-visible changes)
- [ ] New UI strings are in `Fader/Localizable.xcstrings` with a pt-BR translation
- [ ] No em dash characters (U+2014)
- [ ] Audio code follows the rules in [AGENTS.md](https://github.com/Lokasta/fader/blob/main/AGENTS.md#rules-hard-won-keep-them) (no taps without permission, real-time safe IO blocks, no network)
