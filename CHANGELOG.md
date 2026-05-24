# Changelog

All notable changes to this project will be documented in this file.

The format follows Keep a Changelog and the project uses Semantic Versioning.

## [Unreleased]

## [0.5.3] - 2026-05-24

### Added

- Comprehensive phase-boundary logging across `TTSSpeechSynthesizer` and
  `TTSPlaybackController`. Every public entry now emits a
  `logger.info("<method>: ENTRY ...")` line; every catch site emits a
  standardized `logger.error("ERROR <site>: modelID=… stage=… underlying=…")`
  line before re-throwing. First-buffer arrival, per-chunk progress in
  long-form synthesis, and per-25-buffer markers in streaming all log so
  hangs are visible in real time. Subsystem `technology.fil.ttsmlx`,
  categories `Synthesizer` / `Playback` / `Prefetch`.
- `TTSSpeechSynthesizer.snapshot()` — read-only state dump (warmed model
  IDs, `events()` subscriber count, whether a closure handler is set).
  Also writes itself to `logger.info` so it correlates with synthesis
  activity in Console.
- `TTSSpeechSynthesizer` emits a `logger.warning` line when a stream or
  `synthesizeStream` call finishes with **zero buffers** — the most
  common "stopped generating" symptom — with the three usual causes
  spelled out in the message.
- `TTSPlaybackController` emits a `logger.warning` when a stream drains
  with zero buffers scheduled, pointing the reader at the matching
  `synthesizeStream` log.
- `Docs/debugging.md` — how to read TTSMLX logs: Console.app filter
  syntax, what a healthy trace looks like, mapping from error-site
  names to failed phases, capture commands.

### Changed

- `connectIfNeeded` in `TTSPlaybackController` now logs the engine
  start/format transitions and surfaces `engine.start()` failures with
  a hint about the most common cause (missing `AVAudioSession`
  configuration on the app side).

## [0.5.2] - 2026-05-24

### Added

- `TTSMLX.bake(_:voice:options:into:chunker:progressHandler:)` — top-level
  one-call helper to produce a `TTSPreparedNarration` bundle without
  constructing a `TTSSpeechSynthesizer` and without picking a model. Uses
  `recommendedModel(for: .current)` against the device profile. For build
  scripts, dev panels, and any author-time path that doesn't otherwise
  need a synthesizer instance. The instance-method
  `synthesizer.prepareNarration(...)` is still there for callers that want
  to pin a specific model or share a synthesizer with the live path.

### Changed

- `TTSPlaybackController.currentTime` doc comment reworded. Previous
  wording ("Rate-scaled: at 2× rate, two seconds of source audio render
  per real second") was technically accurate but actively misleading
  about the property that matters at the call site. Now leads with
  "rate-independent source-audio seconds" — matching the migration doc
  — and explains the implementation detail second, where it belongs.

## [0.5.1] - 2026-05-24

### Fixed

- **Catalog regression on iPhone.** `Pocket-TTS` was hard-gated to
  `minimumDeviceClass: .iPad` in 0.4 / 0.5.0 based on conservative
  paranoia, not measured data. ReadMeBook shipped Pocket-TTS on iPhone
  through 0.3 with no OOM reports. Lowered to `.iPhone`; the existing
  `peakMemoryMB: 600` is the correct gate and trivially passes on any
  modern iPhone (6–8GB RAM). Same fix applied to `Qwen3-TTS` (was `.iPad`
  without a documented non-memory reason; now `.iPhone`).

### Changed

- `Orpheus` keeps `minimumDeviceClass: .mac` but the catalog entry now
  documents **why**: a 6GB resident peak leaves <1GB headroom on 8GB
  iPhones / iPads, and iOS will jetsam-kill the app under background
  memory pressure even though `physicalMemoryMB` nominally fits. Gate
  lifts only with empirical iOS-side validation.
- `TTSModelCapabilities.peakMemoryMB` and `.minimumDeviceClass` doc
  comments now state the principle explicitly: use `peakMemoryMB` for
  memory pressure, use `minimumDeviceClass` **only** for non-memory
  reasons (ANE-only kernels, missing GPU features, jetsam headroom
  tighter than memory alone can express). Class gates set without a
  comment justifying the non-memory reason are treated as bugs.
- `Docs/0.5-migration.md` adds a "fallback fragility" note: when
  `isSupported(on:) == false` rasterizes into the app's fallback engine,
  that fallback path needs to be as robust as the primary — including
  defensive writes to `MPNowPlayingInfoCenter`, which has its own
  dispatch-queue constraints and crashes under
  `_dispatch_assert_queue_fail` when written from the wrong queue.

### Added

- Catalog-intent regression test (`TTSDeviceProfileTests`): every
  validated model that advertises `minimumDeviceClass: .iPhone` must fit
  a 6GB iPhone profile. Catches silent re-regression of over-gating.

## [0.5.0] - 2026-05-24

### Added

- `TTSPreparedNarration` + `TTSPreparedNarrationManifest` — self-contained,
  redistributable bundle of pre-generated audio plus word-level timings.
  Layout: directory with `manifest.json` + `chunks/NNN.wav`. Versioned schema
  (`schemaVersion: 1`). Plays at runtime without MLX, the model, or a network
  — designed for onboarding voiceovers, sample chapters, and reproducible
  demos. `TTSPreparedNarrationError` covers manifest-missing / malformed /
  schema-too-new / chunk-audio-missing.
- `TTSSpeechSynthesizer.prepareNarration(_:using:options:into:chunker:progressHandler:)`
  — author-time helper that chunks text, generates per-chunk WAVs into the
  bundle, measures each chunk's duration, computes word timings, and writes
  the manifest atomically.
- `TTSPlaybackController.play(narration:onWord:onPlaybackEnd:)` — runtime
  helper that schedules every chunk's WAV in order, reports `duration` as
  the bundle total, and fires `onWord` callbacks against `currentTime` as
  playback crosses each word boundary. Pitch-preserving speed control still
  applies; word callbacks remain in sync at any rate because both
  `currentTime` and the word timeline are expressed in source-audio seconds.
- `TTSPrefetchQueue.replace(_:)` — atomic cancel-and-enqueue helper for
  voice or model switches. The in-flight item finishes on the previous
  configuration; pending items are dropped and replaced with the new
  request set. Cache keys include voice, so previously-prefetched audio for
  the old voice stays valid.
- `TTSPlaybackController.currentTime: TimeInterval` — wall-clock seconds of
  audio actually rendered for the current session. Respects `seek(to:)` for
  file playback. Resets on `stop()`.
- `TTSPlaybackController.duration: TimeInterval?` — total length for file
  playback; `nil` for stream playback (length unknown until the stream ends).
- `TTSPlaybackController.timePulse(interval:)` — `AsyncStream<TimeInterval>`
  that ticks playback position while audio is active. Finishes when state
  becomes `.stopped` or `.idle`. Multiple independent subscribers supported.
- `TTSPlaybackController.seek(to:)` — seek inside the currently playing file.
  Preserves prior playing/paused state; seeking at or past `duration` finishes
  playback as if it had played to the end. Throws
  `TTSPlaybackController.PlaybackError.seekUnsupportedForStream` for stream
  playback (no addressable timeline).
- `TTSWordTiming { characterRange: Range<Int>, offset: TimeInterval,
  duration: TimeInterval }` — one word's timing within a chunk. Ranges are in
  the original input coordinate space so consumers can drop a highlight
  straight on the source text.
- `TTSChunkInfo.wordTimings(forDuration:)` — character-proportional word
  timings for a chunk that tile exactly to the supplied duration (no rounding
  drift on the final word). Useful for word-level highlight overlays without
  per-token model callbacks.
- `TTSDiagnostic.chunkTimings(modelID:chunkIndex:timings:)` — emitted by
  `synthesizeLong` right after `.chunkFinished` once the chunk's actual
  duration is known.
- `TTSSpeechSynthesizer.events()` — typed `AsyncStream<TTSDiagnostic>` of
  every diagnostic the synthesizer emits. Prefer over the closure handler in
  SwiftUI consumers — drives a `for await event in await synthesizer.events()`
  loop without bridging through `NotificationCenter`. Each call returns an
  independent stream; the closure handler still fires in parallel.

## [0.4.0] - 2026-05-23

Distribution note: this release continues to use a local-path dependency on
`../mlx-audio-swift` during active fork development. Tagging is for internal
tracking and downstream consumers who already vendor the sibling fork. See
`Docs/mlx-audio-fork.md` for the workflow.

### Added

- `TTSTextChunker` with `chunks(for:)` (string-only) and `chunkInfos(for:)`
  (position-aware — returns ranges into the original input so apps can map
  "currently-playing chunk" back to the source text for highlighting).
- `TTSAudioCache` actor — content-addressable on-disk cache with SHA-256 keys
  over `(modelID|voice|text)`, atomic `.part` writes, `AVAudioFile` validity
  check, and `prune(toMaxBytes:)` (purges abandoned `.part` files first,
  then oldest by mtime).
- `TTSDiagnostic` event enum and `TTSDiagnosticHandler` typealias. Events
  cover request start, model resolve/download/load, first-buffer latency,
  per-chunk start/finish, streaming/synthesis finished, error, and unload.
- `os.Logger` integration on the synthesizer (subsystem
  `technology.fil.ttsmlx`).
- `TTSDeviceClass` (iPhone/iPad/mac, `Comparable` by memory rank) and
  `TTSDeviceProfile.current` (reads `UIDevice` + `ProcessInfo.physicalMemory`).
- `TTSModelCapabilities.peakMemoryMB` and `.minimumDeviceClass`, populated
  with empirical values for every validated catalog entry (Pocket TTS now
  gated to iPad/Mac, Orpheus to Mac, etc.).
- `TTSModelDescriptor.isSupported(on:)` and `TTSMLX.recommendedModel(for:)`
  for device-aware model selection.
- `TTSError` cases: `.deviceUnsupported`, `.outOfMemory`, `.modelLoadFailed`,
  `.generationFailed`, `.networkUnavailable`; plus
  `TTSError.wrap(_:modelID:stage:)` that maps raw `Error`s and `NSURLError`s
  into the right typed case.
- `TTSSpeechSynthesizer.synthesizeLong(_:using:options:chunker:)` — streams
  audio for long-form text by chunking, flattens per-chunk streams into a
  single `AsyncThrowingStream`. Emits `.chunkStarted(characterRange:)` and
  `.chunkFinished` diagnostics per chunk.
- `TTSSpeechSynthesizer.synthesizeAll(_:into:)` — pre-generates the entire
  text to a single combined WAV file (offline / "download for later" mode).
- `TTSSpeechSynthesizer.prepareForPlayback(using:initialText:cache:)` —
  warms the model and pre-generates the first chunk into the supplied
  `TTSAudioCache` so the first tap on Play is instant.
- `TTSSpeechSynthesizer.warmUp(_:)`, `isLoaded(_:)`, `unload(_:)`,
  `unloadAll()`, `handleMemoryWarning()` lifecycle API for iOS memory
  pressure.
- `TTSSpeechSynthesizer.init(modelStore:diagnosticHandler:)` and
  `setDiagnosticHandler(_:)` so consumers can subscribe to lifecycle events.
- `TTSPrefetchQueue` actor — background queue that fills `TTSAudioCache`
  while playback continues. Honors `ProcessInfo.thermalState` (pauses on
  `.serious` by default) and `isLowPowerModeEnabled`. Configurable via
  `TTSPrefetchPolicy`.
- `TTSPlaybackController` (`@MainActor`) — `AVAudioEngine` +
  `AVAudioUnitTimePitch` wrapper with pitch-preserving rate control
  clamped to 0.5–2.0×, pause/resume/stop, and stream-or-file playback
  entry points.

### Changed

- Pinned all remote dependencies to exact validated versions so
  `swift package resolve` cannot silently drift:
  - `mlx-swift` `.exact("0.31.3")` (was `from: "0.30.6"`)
  - `mlx-swift-lm` `.exact("2.31.3")` (was `from: "2.30.6"` — held on the
    2.x line because 3.x decouples `MLXLMCommon` from `Tokenizers` and
    `Hub`, which the local `mlx-audio-swift` fork still imports directly)
  - `swift-huggingface` `.exact("0.8.1")`
- `TTSModelCapabilities` decoding now tolerates older encoded values
  (the new `peakMemoryMB` and `minimumDeviceClass` fields are
  `decodeIfPresent`).

### Fixed

- Caught errors in the synthesizer are now classified by stage (download
  vs load vs generation) and wrapped into the right `TTSError` case, so
  consumers can distinguish network failures from model failures without
  inspecting error strings.

## [0.3.3] - 2026-04-04

### Changed

- Clarified that `TTSMLX` is a TTS-only wrapper over the local `../mlx-audio-swift` checkout and does not expose upstream STT or STS surfaces yet.
- Tightened the built-in catalog so it only advertises model families the current local Swift runtime can actually synthesize with.
- Removed `Kitten TTS` from the built-in runtime-supported catalog and kept `Echo TTS` out of the default supported list until the local runtime exposes a complete end-to-end implementation again.
- Updated Hugging Face search behavior so known upstream-only TTS families from `mlx-audio v0.4.2`, including `Irodori-TTS`, `HumeAI TADA`, `KugelAudio TTS`, and `Voxtral-4B-TTS-2603`, can appear as discovery-only results without being mislabeled as runnable.

### Fixed

- Prevented wrapper/runtime mismatches where the demo could surface unsupported models as if they were safe to synthesize with locally.
- Prevented `Kitten TTS` from being labeled runnable in the wrapper and demo while the local backend still throws for generation and streaming.
- Made streamed-output behavior explicit in the wrapper and demo: streaming remains a buffer-delivery path and does not record a wrapper-managed output artifact.
- Added regression coverage for discovery-only upstream TTS families and the current local runtime support boundary.

## [0.3.2] - 2026-03-18

### Added

- Demo app: automatically sync generation profile to each selected model’s default.
- Demo app: added reference-audio controls with capability-based support gating.
- Demo app: added streaming capability awareness for composer and stream controls.

### Fixed

- Demo app: preserved backward-compatible persisted settings while adding profile and reference-audio settings fields.
- Demo app: cleared unsupported reference-audio inputs when the selected model cannot handle them.

## [0.3.1] - 2026-03-16

### Changed

- Updated `mlx-audio-swift` to `0.1.2`.
- Added `Echo TTS` to the built-in supported model catalog.
- Tightened model search filtering so the demo only surfaces TTS models that the current loader can actually open.

### Fixed

- Prevented unsupported search results such as `kokoro` from appearing and then failing at synthesis time.
- Added regression coverage for supported-model filtering and Echo model discovery.

## [0.1.0] - 2026-03-10

### Added

- Initial `TTSMLX` Swift package for Hugging Face text-to-speech with MLX.
- Actor-based synthesis and model management APIs.
- Streaming synthesis support for lower-latency playback.
- Progress reporting for downloads and synthesis.
- Hugging Face model search, metadata loading, and local cache management.
- SwiftUI demo app with model download, synthesis, playback, replay, export, and reveal actions.
- Recommended model list and usage documentation.
