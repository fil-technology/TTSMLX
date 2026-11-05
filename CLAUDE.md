# Claude session instructions

## Before doing anything else

`URGENT.md` used to track pre-release blockers and was deleted on 2026-11-04 once
all five items were resolved (runtime release, mlx-swift pin, MOSS validation,
durable iOS model cache, consumer mirror). If a new blocker appears, recreate the
file and this rule applies again: read it and surface its contents to the user at
the start of every session, before acting on whatever they asked for.

## Build and test

- `swift build` — framework. Needs the Swift 6.3 toolchain or newer (Xcode 26.3+): `mlx-swift` 0.33 requires it. CI runs on `macos-26`.
- `swift test` — full suite (currently 263 tests across 41 suites; should always be green on `main`).
- `xcodebuild -project DemoApp/TTSMLXDemo.xcodeproj -scheme TTSMLXDemo-macOS -configuration Debug build` — demo app, macOS target. iOS target also exists.
- After any change to `mlx-audio-swift` (local path dependency), wipe `~/Library/Developer/Xcode/DerivedData/TTSMLXDemo-*` and reset SwiftPM package caches in Xcode — incremental builds do not pick up local-path package source changes reliably.

## Benchmarks

- `Tools/bench.sh mac [models…]` runs the shared harness (`Source/TTSBenchmark.swift`) on this Mac through `xcodebuild test` (plain `swift test` has no Metal library); `DEVICE=<udid> Tools/bench.sh device [models…]` runs it on a phone through the demo app's `--benchmark` argument, `Tools/bench.sh pull` copies the reports back. Reports go to `Benchmarks/results/*.json`; `python3 Tools/render-benchmarks.py` rewrites `Docs/benchmarks.md`.
- Always run with the MLX cache capped (the harness default, 512 MB): uncapped, one long-form run on macOS reached 24 GB resident and filled the disk through swap.
- Do not run benchmarks while another build or test run is going; the numbers are wall-clock.
- On a phone the demo app shows `RunStatusView` (stage, log, elapsed) and disables the idle timer for the run; a cancelled trial means the app went inactive (lock, shade, call) and is retried twice. Watch the Mac side through the `devicectl … --console` stream (`[bench]` lines).

## Versioning and releases

- Releases are tagged `vX.Y.Z` on `main`. Last release: see `CHANGELOG.md`.
- Bump version is communicated via CHANGELOG entries and git tags only; there's no version literal in `Package.swift`.
- Feature work happens on `feature/<short-name>` branches, then merged into `main` with `--no-ff` to preserve the branch history.
