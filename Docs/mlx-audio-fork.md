# MLXAudio Fork Workflow

`TTSMLX` is currently wired to a local sibling checkout at `../mlx-audio-swift` for active development on upstream model support.

## Why

New model-family support belongs in `mlx-audio-swift`, not in the app wrapper:

- model routing
- config parsing
- tokenizer loading
- weight loading
- audio decoding / generation

`TTSMLX` should stay focused on discovery, download UX, metadata, and app integration.

## Current Setup

`Package.swift` uses:

```swift
.package(path: "../mlx-audio-swift")
```

This is intended only for local development while the fork is being prepared.

## Before Publishing

Replace the local path dependency in `Package.swift` with the public fork URL, for example:

```swift
.package(url: "https://github.com/<org>/mlx-audio-swift.git", from: "<version>")
```

Then run:

```bash
swift package resolve
swift test
```

## Suggested Next Steps In The Fork

1. Add a backend for `kitten_tts`.
2. Add a backend registry entry for each new model family.
3. Add family-level unit tests for type normalization and repo inference.
4. Add at least one smoke test repo per supported family.
