# Changelog

All notable changes to this project will be documented in this file.

The format follows Keep a Changelog and the project uses Semantic Versioning.

## [Unreleased]

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
- `TTSSpeechSynthesizer.events()` — typed `AsyncStream<TTSDiagnostic>` of
  every diagnostic the synthesizer emits. Prefer over the closure handler in
  SwiftUI consumers — drives a `for await event in await synthesizer.events()`
  loop without bridging through `NotificationCenter`. Each call returns an
  independent stream; the closure handler still fires in parallel.
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
