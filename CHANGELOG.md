# Changelog

All notable changes to this project will be documented in this file.

The format follows Keep a Changelog and the project uses Semantic Versioning.

## [Unreleased]

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
