# Claude session instructions

## Before doing anything else

**Read [URGENT.md](URGENT.md) and surface its contents to the user at the start of every session, before acting on whatever they asked for.** That file tracks pre-release blockers that affect what's safe to ship from this repo. Treat it as a hard precondition until it's deleted (which happens when its items are all resolved).

If `URGENT.md` does not exist, this instruction is satisfied — proceed normally.

## Build and test

- `swift build` — framework.
- `swift test` — full suite (currently 97 tests across 14 suites; should always be green on `main`).
- `xcodebuild -project DemoApp/TTSMLXDemo.xcodeproj -scheme TTSMLXDemo-macOS -configuration Debug build` — demo app, macOS target. iOS target also exists.
- After any change to `mlx-audio-swift` (local path dependency), wipe `~/Library/Developer/Xcode/DerivedData/TTSMLXDemo-*` and reset SwiftPM package caches in Xcode — incremental builds do not pick up local-path package source changes reliably.

## Versioning and releases

- Releases are tagged `vX.Y.Z` on `main`. Last release: see `CHANGELOG.md`.
- Bump version is communicated via CHANGELOG entries and git tags only; there's no version literal in `Package.swift`.
- Feature work happens on `feature/<short-name>` branches, then merged into `main` with `--no-ff` to preserve the branch history.
