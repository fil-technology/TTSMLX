# Changelog

All notable changes to this project will be documented in this file.

The format follows Keep a Changelog and the project uses Semantic Versioning.

## [Unreleased]

## [0.6.0] - 2026-05-24

A perf + reliability + ergonomics release. Live streaming now keeps
weights resident across calls, runs off the main thread, survives
backgrounding without crashing, and drives word highlights from actual
playback time. Voice switching is independent (per-voice sub-bundles)
and clean (model eviction on variant change). The framework now owns
the on-disk bundle layout via `TTSAudioCache`, and a one-call
`speakStreaming(...)` helper collapses the canonical reader-app flow.

### Added

- `TTSSpeechSynthesizer.speakStreaming(text:using:options:cache:playback:onWord:onPlaybackEnd:progressHandler:)`
  — one-call reader flow that wires streaming + cache + playback +
  playback-driven word highlighting. Replaces the four-call wiring most
  consumers had to assemble themselves.
- `TTSAudioCache.narrationBundle(modelID:text:)`,
  `availableVariants(modelID:text:)`, and `migrate(from:)` — the
  framework now owns bundle URL derivation. Voice and language coexist
  as per-voice sub-bundles inside the same parent URL.
- `TTSSpeechSynthesizer.streamAndCacheNarration(_:using:options:cache:chunker:progressHandler:)`
  overload that uses `TTSAudioCache` for URL derivation. The original
  `cacheBundleAt: URL` variant stays for export/distribution flows.
- `TTSPlaybackController.play(stream:synthesizer:onWord:onPlaybackEnd:)`
  — playback-driven word highlighting for streaming synthesis.
  Subscribes to `synthesizer.events()`, builds an absolute-time
  timeline as `chunkFinished` / `chunkTimings` events arrive, and
  fires `onWord` based on `AVAudioPlayerNode.currentTime`. Replaces
  event-driven highlighting, which leads the audio by however much was
  buffered ahead.
- `TTSDiagnostic.modelLoadServedFromCache(modelID:)` — emitted when
  `prepareModel` reused a previously-loaded `SpeechGenerationModel`
  instance instead of running the load pipeline.
- `TTSDiagnostic.cancelledByBackground(cancelledCount:)` — emitted when
  the framework auto-cancels in-flight generation in response to a
  background-lifecycle notification.
- `TTSSpeechSynthesizer.cancelAllInFlight(reason:)` — cancel every
  tracked drain Task synchronously; safe to call from any isolation.
- `TTSSpeechSynthesizer.allowsBackgroundGeneration: Bool` — opt-in for
  apps that own their own `UIApplication.beginBackgroundTask` assertion
  and accept that iOS still rejects Metal compute regardless.
- `TTSPreparedNarration.subBundleURL(in:voice:language:)`,
  `subBundleSlug(voice:language:)`, `availableVariants(at:)`, and
  `init(importing:voice:language:)` — public surface for the new
  per-voice sub-bundle layout. Legacy single-voice bundles auto-migrate
  on first use.
- `TTSError.modelDownloadFailed(file:status:)` — distinct case for
  per-file failures during the direct-host (non-HF) download path.
- Direct-host model downloads: `TTSModelDescriptor.modelURL` + `files`
  let descriptors declare a static base URL plus a file list, bypassing
  the HF resolver. Suitable for self-hosted (e.g. Cloudflare R2) models.

### Changed

- `TTSSpeechSynthesizer` now caches loaded `SpeechGenerationModel`
  instances across calls. `warmUp(_:hfToken:progressHandler:)` actually
  keeps weights resident now; `unload(_:)`, `unloadAll()`, and
  `handleMemoryWarning()` drop them for real.
- Variant-aware cache eviction: switching `(voice, language)` evicts
  the cached instance and reloads from disk (~300 ms). Prevents
  residual state in upstream layers (Mimi, FlowLM, ProjectedTransformer)
  from leaking voice-A character into voice-B output and vice-versa.
- `synthesizeStream`, `synthesizeLong`, `synthesizeAll`,
  `streamAndCacheNarration`, `prepareNarration`, `prepareForPlayback`,
  and `TTSMLX.bake` are no longer `@MainActor`. Heavy synthesis work
  runs on the synthesizer actor's executor. The non-Sendable MLX
  stream is still created and drained on `@MainActor` inside an
  internal Task, because upstream `generatePCMBufferStream` requires it.
- `.ttsnarration` bundles use a per-voice sub-bundle layout
  (`<bundle>/voices/<voice>.<language>/manifest.json` +
  `<bundle>/voices/<voice>.<language>/chunks/`). Existing single-voice
  bundles auto-migrate on first read; their cached chunks survive.
- The DemoApp restructured into a TabView (Synthesize / Bundles /
  Models). New Models tab manages built-in + UserDefaults-persisted
  custom descriptors. New Bundles tab lists baked bundles per variant
  and bakes via `prepareNarration` or `streamAndCacheNarration`.

### Fixed

- **`broadcast_shapes` KV-cache contamination crash** on long sessions
  and voice switches. Caused by `MimiAdapter.resetState()` only zeroing
  the cache offset while the underlying MLXArray storage kept its
  stale shape, which attention paths reading `.dim(2)` directly used
  instead of the offset. Patched upstream `mlx-audio-swift`:
  `resetState()` now rebuilds the encoder/decoder caches outright;
  `PocketTTSModel.generate()` calls `mimi.resetState()` defensively at
  the top of every call; the shared `MLXAudioCodecs/Mimi/Mimi.swift`
  gets the same fix and a new public `resetDecoderCache()` for the
  streaming-decoder path. (See "Notes" below — these patches live in
  the local mlx-audio-swift checkout, not in this repo.)
- **`kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted`
  crash on app backgrounding.** The synthesizer now owns a synchronous
  shutdown coordinator (`TTSLifecycleCoordinator`) shared between the
  notification observer (main thread) and every drain Task. On
  `UIApplication.willResignActive` / `didEnterBackground` and the
  matching `UIScene` events, the observer sets `isShuttingDown` true,
  cancels tracked Tasks synchronously, and calls
  `MLX.Stream.gpu.synchronize()` to drain queued Metal command buffers
  before iOS clamps GPU access. Drain Tasks check the flag before every
  upstream iteration so no further submissions land past the signal.
- **Streaming word highlight flushing on every inter-chunk idle.** The
  streaming observer copy-pasted the prebaked-narration loop's
  idle-handling, which unconditionally fired every queued word and
  exited the observer. Mid-stream `.idle` is transient (engine waiting
  for the next chunk's buffers); the flush-and-exit branch is now
  gated on `streamingFinished`.
- Stray `await` on `nonisolated` `TTSAudioCache.key(modelID:voice:text:)`
  in `prepareForPlayback` no longer warns.
- Sandbox-aware cache root resolution for iOS + sandboxed macOS apps.

### Performance

- Subsequent `synthesize*` calls on the same model + voice + language
  skip the MLX load pipeline entirely (cache hit on the
  `SpeechGenerationModel` instance). The first call is unchanged; the
  second and on save ~0.3–1.5 s each.
- `warmUp(model)` now does what its name promises — call it once when
  the model finishes downloading (e.g. end of onboarding) and first
  Play is instant.

### Notes for consumers

- **Pull the patched `mlx-audio-swift` checkout.** The `broadcast_shapes`
  fix lives there, not in TTSMLX. Without it, the model cache surfaces
  the latent KV-cache bug on voice switch.
- **Wipe DerivedData + Reset Package Caches** on first integration of
  this release. Xcode aggressively caches local-path package compile
  output and won't pick up the mlx-audio-swift patches otherwise.
- **iOS background MLX generation is impossible.** The OS rejects Metal
  compute regardless of background-task assertions. For indefinite
  background playback, pre-bake a chapter with `prepareNarration(...)`
  (foreground only) and play the resulting `TTSPreparedNarration`
  bundle — that path is MLX-free at playback time. See the README's
  "Background playback continuity" section.
- **Migrate to `speakStreaming(...)` + the cache overload** if you're
  driving the canonical reader flow. Old call shapes still work; the
  new one removes the room for two-subscriber highlight bugs.

## [0.5.4] - 2026-05-24

### Added

- `TTSSpeechSynthesizer.streamAndCacheNarration(_:using:options:cacheBundleAt:chunker:progressHandler:)`
  — runtime per-chunk progressive cache. Reuses the `TTSPreparedNarration`
  bundle format (shipped in 0.5.0 for onboarding voiceovers) as a chapter-
  level "generate once, replay forever" cache:
  - Each chunk's WAV is finalized to disk the moment that chunk completes,
    not at the end of the stream. Mid-stream cancellation (backgrounding,
    watchdog, user tap) preserves every chunk done so far.
  - Next call with the same `cacheBundleAt: URL` reads the manifest,
    validates `model` / `voice` / `text` match, and replays cached chunks
    **without invoking MLX**. Missing chunks fall through to generation.
  - Mismatched manifests (different model, voice, or text) auto-wipe the
    stale bundle so callers can use a stable `bundleURL` across switches
    without manual invalidation.
  - `chunkStarted` / `chunkFinished` / `chunkTimings` diagnostics fire for
    cached chunks too, so highlight UIs don't need to distinguish replay
    from generation.
- `Docs/0.5.4-app-perf-brief.md` — consumer-app upgrade guide that
  explains the "regenerates every time" symptom (cause: per-chapter cache
  + background cancellation = lost in-flight writes), the new primitive,
  and 6 additional app-side perf fixes (hand-rolled hash replacement,
  warmUp on launch, prefetch window, AVAudioSession centralization,
  per-buffer log/MainActor-hop removal).

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
