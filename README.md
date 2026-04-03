# TTSMLX

Small Swift package for text-to-speech with Hugging Face models running through `mlx-audio-swift`.

`TTSMLX` is intentionally TTS-only. Upstream `mlx-audio` also supports STT, STS, quantization utilities, and server paths, but those surfaces are not wrapped by this package yet.

## Features

- Simple actor-based API
- Streaming playback API for long-form speech
- Built-in catalog of supported MLX TTS models
- Hugging Face model search
- Lazy model download and cache management
- Voice and language selection when the model supports them
- Reference-audio voice cloning hooks

## Supported Models

These models are included in the built-in `TTSMLX.supportedModels` catalog:

- [Marvis-AI/marvis-tts-250m-v0.2-MLX-8bit](https://huggingface.co/Marvis-AI/marvis-tts-250m-v0.2-MLX-8bit) - best default choice for a balanced quality/size tradeoff.
- [mlx-community/pocket-tts](https://huggingface.co/mlx-community/pocket-tts) - smallest and simplest option when startup speed and low memory matter most.
- [mlx-community/Soprano-80M-bf16](https://huggingface.co/mlx-community/Soprano-80M-bf16) - compact model that is still easy to run locally on Apple Silicon.
- [mlx-community/VyvoTTS-EN-Beta-4bit](https://huggingface.co/mlx-community/VyvoTTS-EN-Beta-4bit) - English Qwen3-based option when you want a smaller alternative to full Qwen3-TTS.
- [mlx-community/orpheus-3b-0.1-ft-bf16](https://huggingface.co/mlx-community/orpheus-3b-0.1-ft-bf16) - larger multi-voice LlamaTTS model with expressive built-in speakers.
- [mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit](https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit) - strongest general-purpose option here when you want better quality, multilingual support, and voice-cloning style inputs.
- [mlx-community/kitten-tts-mini-0.8](https://huggingface.co/mlx-community/kitten-tts-mini-0.8) - compact runtime-supported option exposed by the current local `mlx-audio-swift` loader.

Quick picking guide:

- Start with `Marvis` if you want the safest default.
- Use `Pocket TTS` for fast, lightweight local generation.
- Use `Orpheus` when you want more built-in English voice choices.
- Use `Qwen3-TTS` when voice options, multilingual output, or cloning features matter more than model size.
- Try `VyvoTTS` if you want a smaller English Qwen3-style model.
- Try `Kitten TTS` when you want a smaller runtime-supported alternative in the built-in catalog.

Current upstream note:

- `TTSMLX` keeps the local path dependency on `../mlx-audio-swift` during active fork development. This package does not pin a standalone `mlx-audio` backend version by itself.
- The wrapper catalog only lists model families that the current local `mlx-audio-swift` loader can open today.
- New upstream `mlx-audio v0.4.2` TTS families such as `Irodori-TTS`, `HumeAI TADA`, `KugelAudio TTS`, and `Voxtral-4B-TTS-2603` may still appear in model search as discovery-only results, but they are intentionally marked unsupported until the local Swift backend gains loaders for them.
- Upstream additions outside the TTS wrapper scope, such as `Cohere Transcribe ASR`, `Qwen2-Audio-7B-Instruct`, `Moshi STS`, and Distil-Whisper documentation updates, are not exposed through `TTSMLX` yet.

Nothing in this catalog is downloaded automatically.
Models are downloaded only when you explicitly call `ensureDownloaded(...)`, or when you synthesize using a specific selected model.

## Usage

```swift
import TTSMLX

let synthesizer = TTSSpeechSynthesizer()
let result = try await synthesizer.synthesize(
    "Hello from TTSMLX",
    using: TTSMLX.supportedModels[0],
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
.package(url: "https://github.com/fil-technology/TTSMLX.git", from: "0.3.0")
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
    using: TTSMLX.supportedModels[0],
    options: .init(streamingInterval: 1.0)
)

for try await chunk in stream {
    print("chunk sample rate:", chunk.sampleRate)
    print("frames:", chunk.buffer.frameLength)
}
```

Use `synthesize(...)` when you want a finished WAV file.
Use `synthesizeStream(...)` when you want lower-latency playback and chunk-by-chunk delivery.
The current wrapper treats streaming as a buffer-delivery API: it does not surface a persisted file artifact for streamed runs, even if future upstream runtimes save one internally.

## Demo App

A small SwiftUI demo app is included at [DemoApp](DemoApp).

Open it with:

```bash
cd DemoApp
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

// Downloads happen one model at a time and only for the descriptor you pass in.
```

## Model Metadata

You can ask the framework for model metadata sourced from Hugging Face tags and `config.json`:

```swift
let store = TTSModelStore()
let metadata = try await store.fetchMetadata(for: "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit")

print(metadata.languageIdentifiers)
print(metadata.modelType ?? "unknown")
print(metadata.sampleRate ?? 0)
print(metadata.storageSizeBytes ?? 0)
```

`storageSizeBytes` is the remote repository size reported by the Hugging Face model API.

## Voice Selection

```swift
let pocketTTS = TTSMLX.supportedModels.first { $0.id == "mlx-community/pocket-tts" }!

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
