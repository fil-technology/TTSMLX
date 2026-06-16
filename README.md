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
- Content-addressable `TTSAudioCache` + background `TTSPrefetchQueue` with thermal/Low-Power-Mode gating
- `TTSPlaybackController` with pitch-preserving speed control (0.5×–2.0×), `currentTime`/`duration`/`seek(to:)`, and a `timePulse` async stream for scrubber UIs
- Per-chunk and per-word timing diagnostics for highlight overlays (`TTSDiagnostic.chunkTimings`, `TTSChunkInfo.wordTimings(forDuration:)`)
- Typed `synthesizer.events()` `AsyncStream<TTSDiagnostic>` for SwiftUI consumers
- `TTSPreparedNarration` bundles — ship pre-generated audio + word timings with the app, play back instantly without MLX or model download (useful for onboarding voiceovers)
- Device-aware model selection (`TTSModelDescriptor.isSupported(on:)`, `TTSMLX.recommendedModel(for:)`)
- Typed errors (`.deviceUnsupported`, `.outOfMemory`, `.modelLoadFailed`, `.generationFailed`, `.networkUnavailable`) and a stage-aware `TTSError.wrap(...)`

See [Docs/0.5-migration.md](Docs/0.5-migration.md) for the consumer-app upgrade briefing for the 0.5 additions.

## Supported Models

These models are included in the built-in `TTSMLX.supportedModels` catalog:

- [Marvis-AI/marvis-tts-250m-v0.2-MLX-8bit](https://huggingface.co/Marvis-AI/marvis-tts-250m-v0.2-MLX-8bit) - best default choice for a balanced quality/size tradeoff.
- [mlx-community/pocket-tts](https://huggingface.co/mlx-community/pocket-tts) - smallest and simplest option when startup speed and low memory matter most.
- [mlx-community/Soprano-80M-bf16](https://huggingface.co/mlx-community/Soprano-80M-bf16) - compact model that is still easy to run locally on Apple Silicon.
- [mlx-community/VyvoTTS-EN-Beta-4bit](https://huggingface.co/mlx-community/VyvoTTS-EN-Beta-4bit) - English Qwen3-based option when you want a smaller alternative to full Qwen3-TTS.
- [mlx-community/orpheus-3b-0.1-ft-bf16](https://huggingface.co/mlx-community/orpheus-3b-0.1-ft-bf16) - larger multi-voice LlamaTTS model with expressive built-in speakers.
- [mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit](https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit) - strongest general-purpose option here when you want better quality, multilingual support, and voice-cloning style inputs.

### Additional variants (implemented, pending on-device validation)

These route to a backend loader that already ships, so they synthesize end to
end and carry full descriptors you can select today — they are staged
`.implemented` rather than `.validated` only because they haven't been
run + memory-profiled on a physical iPhone yet (their `peakMemoryMB` values are
conservative estimates). They appear in `TTSMLX.implementedModels`, not in
`TTSMLX.supportedModels` / `recommendedModel(for:)`, so they are never
auto-selected until promoted. To use one, pass its descriptor explicitly.

- [Qwen3-TTS-12Hz-0.6B-Base-4bit](https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-0.6B-Base-4bit) - smaller-footprint 4-bit build of the multilingual default.
- [Qwen3-TTS-12Hz-1.7B-Base-4bit](https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-1.7B-Base-4bit) - higher-quality multilingual (1.7B); best on 6GB+ iPhones.
- [Qwen3-TTS-12Hz-1.7B-CustomVoice-4bit](https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-4bit) - multilingual with custom-voice / reference-audio conditioning for voice design and cloning.
- [Soprano-80M-4bit](https://huggingface.co/mlx-community/Soprano-80M-4bit) - tiny (~60MB) English model; fastest start and lowest memory.

All Qwen3-TTS entries advertise 15 languages (English, Spanish, French, German,
Italian, Portuguese, Dutch, Polish, Turkish, Russian, Japanese, Korean,
Chinese, Arabic, Hindi).

For a fuller support matrix, including non-runnable tracked models such as `MOSS-TTS-Nano`, see [Docs/ModelSupport.md](Docs/ModelSupport.md) or inspect `TTSMLX.modelCatalog` at runtime.

Quick picking guide:

- Start with `Marvis` if you want the safest default.
- Use `Pocket TTS` for fast, lightweight local generation.
- Use `Orpheus` when you want more built-in English voice choices.
- Use `Qwen3-TTS` when voice options, multilingual output, or cloning features matter more than model size.
- Try `VyvoTTS` if you want a smaller English Qwen3-style model.
Current upstream note:

- As of `0.6.1`, `TTSMLX` pins all MLX dependencies to public tagged forks under `github.com/fil-technology` (`mlx-audio-swift @ 0.1.3-tts.1`, `mlx-swift @ 0.31.5`, whose `mlx` C++ submodule points at `mlx @ v0.31.3-tts-bg-safe.1`). These forks carry the KV-cache reset and iOS background-safe Metal patches that are not yet in any upstream tagged release. The package is now consumable end to end from GitHub with no local-path checkout. See `Docs/mlx-swift-bg-safe-fork.md`.
- The wrapper catalog only lists model families that the current local `mlx-audio-swift` runtime can synthesize with end to end.
- New upstream `mlx-audio v0.4.2` TTS families such as `Irodori-TTS`, `HumeAI TADA`, `KugelAudio TTS`, and `Voxtral-4B-TTS-2603` may still appear in model search as discovery-only results, but they are intentionally marked unsupported until the local Swift backend gains loaders for them.
- `Kitten TTS` may also appear in search as discovery-only for now. The local backend can parse its model assets, but audio generation and streaming are still not wired through yet, so `TTSMLX` does not advertise it as runnable.
- `MOSS-TTS-Nano` is tracked as planned support. As of April 13, 2026, it still requires the upstream OpenMOSS runtime rather than the local `mlx-audio-swift` backend used by `TTSMLX`.
- Upstream additions outside the TTS wrapper scope, such as `Cohere Transcribe ASR`, `Qwen2-Audio-7B-Instruct`, `Moshi STS`, and Distil-Whisper documentation updates, are not exposed through `TTSMLX` yet.

## Model Catalog

`TTSMLX` exposes a public support catalog so app code can distinguish between validated, implemented, and planned models:

```swift
let validated = TTSMLX.validatedModels
let planned = TTSMLX.plannedModels

for entry in TTSMLX.modelCatalog {
    print(entry.displayName, entry.supportStage.rawValue, entry.modelURL?.absoluteString ?? "n/a")
}
```

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
.package(url: "https://github.com/fil-technology/TTSMLX.git", from: "0.5.0")
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

## Reader-app flow — one call

For a reader-style UI (chapter text + playback + word highlighting), the canonical setup is:

```swift
let cache = try TTSAudioCache(directoryURL: documentsDir.appending(path: "Bundles"))
let playback = TTSPlaybackController()
let synthesizer = TTSSpeechSynthesizer()

// Once, after the model finishes downloading (e.g. end of onboarding):
try await synthesizer.warmUp(model)        // keeps weights resident — first Play is instant

// Each chapter:
try await synthesizer.speakStreaming(
    chapterText,
    using: model,
    options: .init(voice: .alba, language: .english),
    cache: cache,
    playback: playback,
    onWord: { word in highlight.current = word.characterRange },
    onPlaybackEnd: { /* next chapter, etc */ }
)
```

`speakStreaming` wires up `streamAndCacheNarration` + `play(stream:synthesizer:onWord:)` for you, so highlights are driven by actual playback time (not generation events) and cached chunks replay instantly on subsequent calls. Voice switching uses per-voice sub-bundles inside the same `cache.narrationBundle(...)` URL — switch to voice B mid-chapter and back, and voice A's cached chunks survive intact.

## Background playback continuity

iOS does not allow MLX/Metal GPU compute in the background. Audio *playback* is allowed; GPU *compute* is not. This is enforced by the OS regardless of background-task assertions, `BGProcessingTask`, audio entitlements, etc. The framework auto-cancels in-flight generation on `willResignActive` / `willDeactivate` / `didEnterBackground` (emitting `TTSDiagnostic.cancelledByBackground`) so the app doesn't crash with `kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted`.

Two implications:

- **Live streaming + background lock**: audio plays from whatever was already scheduled into AVAudioEngine when the app backgrounded — typically seconds, not minutes. When that runs out, silence until the user foregrounds and the app calls `speakStreaming(...)` again to resume. Cached chunks replay instantly; generation picks up where it left off.
- **Indefinite background playback**: use `prepareNarration(...)` to fully pre-bake a chapter to disk while the app is in foreground, then play the resulting `TTSPreparedNarration` via `TTSPlaybackController.play(narration:onWord:)`. That path is MLX-free at playback time and survives any number of background/foreground cycles. Typical baking time: ~5–10× audio duration on iPhone (a 30-minute chapter bakes in 2–5 minutes). The right UX is a "Download for offline" button per chapter.

## Lifecycle hooks

```swift
// Drop cached weights when the OS warns about memory pressure:
NotificationCenter.default.addObserver(
    forName: UIApplication.didReceiveMemoryWarningNotification,
    object: nil, queue: .main
) { [weak synthesizer] _ in
    Task { await synthesizer?.handleMemoryWarning() }
}

// Opt in to background generation only if you own a `beginBackgroundTask`
// assertion AND understand that Metal compute will still be rejected by iOS:
synthesizer.allowsBackgroundGeneration = true
```

The framework's `willResignActive` observer is registered automatically on init; you don't need to call `cancelAllInFlight()` from your own scene-lifecycle hooks unless you have additional cleanup beyond the framework's. Voice switching also evicts the cached model instance to ensure the new voice starts with clean state — a roughly 300 ms reload cost in exchange for not carrying voice-A's residual state into voice B.

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
