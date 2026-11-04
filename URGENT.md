# URGENT — pre-release blockers

Surfaced at the start of every session (see CLAUDE.md). Delete this file when
every item below is resolved.

## 1. `mlx-audio-swift` released (now `0.1.6-tts.1`) — RESOLVED

`feature/moss-tts-nano` is merged into `main` (`--no-ff`) and tagged
`0.1.5-tts.1`, matching how `0.1.4-tts.1` was cut. `Package.swift` pins `0.1.6-tts.1`
(which adds companion-repository support) and `Package.resolved` records it, so other repos —
including the news app — consume TTSMLX normally.

Verified: TTSMLX builds against the tag (not the local path), the resolved
checkout reports `0.1.5-tts.1`, and the full suite passes (125 tests, 20
suites).

The `Packages/mlx-audio-swift` symlink is left in place for future local
development; nothing references it now. To develop against a local checkout
again, swap the `.package(url:exact:)` line for
`.package(name: "mlx-audio-swift", path: "Packages/mlx-audio-swift")` and
remember to restore it before cutting a release.

## 2. `mlx-swift` pin had drifted off the background-safe fork — RESOLVED (0.10.0)

History: the pin drifted to an upstream commit without the patch twice, and
upstream later published its own `0.31.5`, so the fork tag stopped
identifying the fork; the mirror was the only thing keeping resolution right.

**Durable fix — DONE (2026-11-04, runtime migration).** The fork was re-cut
at upstream `mlx-swift 0.33.0` and tagged **`0.33.100`**: a normal version
(prerelease tags are excluded from the `from: "0.33.0"` ranges that upstream
mlx-audio-swift declares) with a patch number upstream will never publish, so
the tag can no longer be confused with an upstream release. The Metal patch
is re-targeted at `device.cpp`, where the completion handler now lives
(`Patches/mlx-c-0.33.0-background-safe-command-buffer.patch`), and
`Tools/verify-mlx-fork.sh` checks that file. `mlx-swift-lm` left the graph,
so only upstream mlx-audio-swift still names `ml-explore/mlx-swift`; the
tracked mirror plus CI verification stay in place for that (see item 5).

## 3. MOSS-TTS-Nano is `.implemented`, not `.validated` — RESOLVED (0.12.0)

Validated on an iPhone 17 (iOS 27.2) on 2026-11-04 with the demo app's
`--moss-validation` mode (Xcode cannot host package tests on a device):
five 60-word passages through the Reader path, debug build. First audio
2.4-3.1 s warm (18 s cold including the load), 1.3x realtime, MLX peak
1.0-1.2 GB, process footprint up to 1.2 GB with 2.2-2.9 GB still available,
no end-of-audio miss in 42 chunks, and the model landed in Application
Support (item 4 confirmed on device). The same harness on macOS
(`Tests/MossDeviceValidationTests.swift` under `xcodebuild`) gives 0.85x
realtime, first audio 4-6 s, MLX peak 1.6 GB, no miss in 42 chunks. The
catalog entry is `.validated` with `peakMemoryMB` 1300.

## 4. Downloaded models live in a directory iOS is allowed to delete — RESOLVED (0.11.1)

`HubCache.default` resolves to `Library/Caches/huggingface/hub` on iOS, which
the system purges under storage pressure without telling the app.

**Fix (0.11.1):** on iOS-family systems `TTSModelStore.defaultModelCacheRoots()`
leads with `Library/Application Support/huggingface/hub`; the store's
`hubCache` (what the synthesizer hands the runtime loader) and
`TTSBackgroundModelDownloader.destinationDirectory` both use that first root,
so every download lands there and every load looks there first. The directory
is marked `isExcludedFromBackup`. `Library/Caches` stays in the lookup list,
and installs found there are moved into the durable root on the store's first
lookup (same-volume renames; a durable copy wins over a stale cached one).
macOS behaviour is unchanged, and an explicit `HF_HOME` / `HF_HUB_CACHE` still
wins everywhere. Covered by `Tests/TTSDurableModelCacheTests.swift`.

Residual: the runtime's Pocket-TTS voice loader fetches voice embeddings with
`HubCache.default` (a few MB, re-fetched automatically if purged); fixing it
needs a fork change.

## 5. Consumers must add a SwiftPM mirror for `mlx-swift` — RESOLVED (0.15.0)

Two packages used to name `mlx-swift`: TTSMLX named the background-safe fork
while upstream `mlx-audio-swift` named `ml-explore/mlx-swift`, and SwiftPM
resolved the shared identity to whichever it met first. Xcode was observed
picking upstream, shipping an app without the Metal background patch, so
every consumer needed a `.swiftpm/configuration/mirrors.json`.

**Fix (0.15.0):** the `mlx-audio-swift` fork (`0.1.8-tts.5`) names
`fil-technology/mlx-swift.git` at `exact: "0.33.100"` itself. Nothing in a
consumer's graph names upstream any more, so no mirror is needed.
`Tools/verify-consumer-resolution.sh` resolves a throwaway mirror-less
consumer package in CI and fails if it gets anything but the fork. The repo
no longer ships `.swiftpm/configuration/mirrors.json` (with a mirror in
effect SwiftPM records the *original* upstream URL in `Package.resolved`,
which is what kept the drift noise alive); `Tools/install-mirrors.sh` stays
for consumers on older versions and `Tools/verify-mlx-fork.sh` still checks
a resolved checkout. The one-line URL change has to be carried over whenever
the fork is rebased on a new upstream release; the consumer check makes a
miss visible.

All five items are resolved; this file can be deleted once the 0.15.0
release is confirmed on a consuming app.
