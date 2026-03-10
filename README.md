# TTSMLX

Small Swift package for text-to-speech with Hugging Face models running through `mlx-audio-swift`.

## Features

- Simple actor-based API
- Streaming playback API for long-form speech
- Recommended MLX TTS models out of the box
- Hugging Face model search
- Lazy model download and cache management
- Voice and language selection when the model supports them
- Reference-audio voice cloning hooks

## Recommended Models

These are the most useful models to start with for `TTSMLX` as of March 10, 2026:

- [Marvis-AI/marvis-tts-250m-v0.2-MLX-8bit](https://huggingface.co/Marvis-AI/marvis-tts-250m-v0.2-MLX-8bit) - best default choice for a balanced quality/size tradeoff.
- [mlx-community/pocket-tts](https://huggingface.co/mlx-community/pocket-tts) - smallest and simplest option when startup speed and low memory matter most.
- [mlx-community/Soprano-80M-bf16](https://huggingface.co/mlx-community/Soprano-80M-bf16) - compact model that is still easy to run locally on Apple Silicon.
- [mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit](https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit) - strongest general-purpose option here when you want better quality, multilingual support, and voice-cloning style inputs.
- [mlx-community/Spark-TTS-0.5B-8bit](https://huggingface.co/mlx-community/Spark-TTS-0.5B-8bit) - useful larger option for English/Chinese workflows if you want another high-capacity model to compare against Qwen3-TTS.

Quick picking guide:

- Start with `Marvis` if you want the safest default.
- Use `Pocket TTS` for fast, lightweight local generation.
- Use `Qwen3-TTS` when voice options, multilingual output, or cloning features matter more than model size.
- Try `Spark-TTS` if your target languages are English or Chinese and you want another larger model family.

## Usage

```swift
import TTSMLX

let synthesizer = TTSSpeechSynthesizer()
let result = try await synthesizer.synthesize(
    "Hello from TTSMLX",
    using: TTSMLX.defaultModels[0],
    options: .init(
        language: .english,
        outputURL: URL.documentsDirectory.appending(path: "hello.wav")
    )
)

print(result.url)
```

## Installation

Add `TTSMLX` to your Swift package dependencies:

```swift
.package(url: "https://github.com/fil-technology/TTSMLX.git", from: "0.1.0")
```

Then depend on the `TTSMLX` product in your target.

## Streaming

For longer passages, use `synthesizeStream(...)` to receive `AVAudioPCMBuffer` chunks as they are generated instead of waiting for a final file:

```swift
import AVFoundation
import TTSMLX

let synthesizer = TTSSpeechSynthesizer()
let stream = try await synthesizer.synthesizeStream(
    "Read this out progressively.",
    using: TTSMLX.defaultModels[0],
    options: .init(streamingInterval: 1.0)
)

for try await chunk in stream {
    print("chunk sample rate:", chunk.sampleRate)
    print("frames:", chunk.buffer.frameLength)
}
```

Use `synthesize(...)` when you want a finished WAV file.
Use `synthesizeStream(...)` when you want lower-latency playback and chunk-by-chunk delivery.

## Demo App

A small SwiftUI demo app is included at [DemoApp](/Users/sviatoslavfil/Development/Fil.Technology/Packages/TTSMLX/DemoApp).

Open it with:

```bash
cd /Users/sviatoslavfil/Development/Fil.Technology/Packages/TTSMLX/DemoApp
./open-xcode
```

## Model Management

```swift
let store = TTSModelStore()

let models = try await store.searchModels(query: "mlx tts")
let installed = try await store.installedModels()

if let model = models.first {
    _ = try await store.ensureDownloaded(model)
}
```

## Model Metadata

You can ask the framework for model metadata sourced from Hugging Face tags and `config.json`:

```swift
let store = TTSModelStore()
let metadata = try await store.fetchMetadata(for: "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit")

print(metadata.languageIdentifiers)
print(metadata.modelType ?? "unknown")
print(metadata.sampleRate ?? 0)
```

## Voice Selection

```swift
let pocketTTS = TTSMLX.defaultModels.first { $0.id == "mlx-community/pocket-tts" }!

let audio = try await TTSSpeechSynthesizer().synthesize(
    "A different voice",
    using: pocketTTS,
    options: .init(voice: .alba)
)
```

## Versioning

`TTSMLX` uses Semantic Versioning.

- Use tagged releases like `v0.1.0`, `v0.2.0`, and `v1.0.0`.
- Consume stable versions from Swift Package Manager tags.
- Use GitHub Releases for release notes and downloadable source snapshots.

For this project, GitHub Releases are the right default distribution mechanism.
GitHub Packages is not required for normal Swift package consumption, because SwiftPM already resolves packages directly from git tags.
