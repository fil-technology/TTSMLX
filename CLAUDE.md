# Claude session instructions

## Before doing anything else

`URGENT.md` used to track pre-release blockers and was deleted on 2026-11-04 once
all five items were resolved (runtime release, mlx-swift pin, MOSS validation,
durable iOS model cache, consumer mirror). If a new blocker appears, recreate the
file and this rule applies again: read it and surface its contents to the user at
the start of every session, before acting on whatever they asked for.

## Build and test

- `swift build` — framework. Needs the Swift 6.3 toolchain or newer (Xcode 26.3+): `mlx-swift` 0.33 requires it. CI runs on `macos-26`.
- `swift test` — full suite (currently 257 tests across 38 suites; should always be green on `main`).
- `xcodebuild -project DemoApp/TTSMLXDemo.xcodeproj -scheme TTSMLXDemo-macOS -configuration Debug build` — demo app, macOS target. iOS target also exists.
- After any change to `mlx-audio-swift` (local path dependency), wipe `~/Library/Developer/Xcode/DerivedData/TTSMLXDemo-*` and reset SwiftPM package caches in Xcode — incremental builds do not pick up local-path package source changes reliably.

## Versioning and releases

- Releases are tagged `vX.Y.Z` on `main`. Last release: see `CHANGELOG.md`.
- Bump version is communicated via CHANGELOG entries and git tags only; there's no version literal in `Package.swift`.
- Feature work happens on `feature/<short-name>` branches, then merged into `main` with `--no-ff` to preserve the branch history.
