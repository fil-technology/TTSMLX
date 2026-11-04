# TTSMLX

Small Swift package for text-to-speech with Hugging Face models running through `mlx-audio-swift`.

`TTSMLX` is intentionally TTS-only. Upstream `mlx-audio` also supports STT, STS, quantization utilities, and server paths, but those surfaces are not wrapped by this package yet.

## Features

- Simple actor-based API
- Streaming playback API for long-form speech
- One voice, feature and control surface across every model: `TTSModelDescriptor.features`, annotated `TTSVoice`s, `TTSSynthesisOptions.instruction` / `emotion` / `speed` and canonical `TTSEventTag` markers, translated per loader
- Natural prosody: punctuation-aware chunking, model-tuned sampling, breath-like pauses and click-free seams between chunks (`TTSChunkJoin`)
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

For every model on the public tts-bench leaderboard — what runs today, what
arrives with the planned runtime migration, and what is blocked and why — see
[Docs/model-support.md](Docs/model-support.md).

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

- As of `0.10.0`, `TTSMLX` runs on upstream `Blaizzy/mlx-audio-swift` v0.1.8 through the thin fork `fil-technology/mlx-audio-swift @ 0.1.8-tts.4` (38 TTS families; the fork only adds `TTSModelRegistry`, MOSS-TTS-Nano bundled voices and the regular-Chatterbox text-pipeline fixes), and on `fil-technology/mlx-swift @ 0.33.100` (upstream 0.33.0 whose `mlx` C++ submodule points at `mlx @ v0.33.0-tts-bg-safe.1`, the iOS background-safe Metal patch). `mlx-swift-lm` is no longer a dependency. See `Docs/mlx-swift-bg-safe-fork.md` and `Docs/model-support.md`.
- The catalog lists a model with a descriptor (selectable by apps) only once TTSMLX has synthesized with it end to end; the 0.1.8 runtime routes to 38 families, and the ones not yet validated here (Higgs v3, OmniVoice, Voxtral, LongCat, Dia, ...) are listed discovery-only with the reason in their `runtimeNotes`. `Docs/model-support.md` has the full tts-bench leaderboard matrix.
- `Kitten TTS` stays discovery-only: the runtime's loader needs `voices.safetensors`, and the mlx-community checkpoint ships `voices.npz`.
- `MOSS-TTS-Nano` runs on upstream's port plus the fork's bundled voices; reference-audio cloning now works through upstream's codec encoder.
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

Where models live: on iOS, iPadOS, tvOS, watchOS and visionOS the store downloads into `Library/Application Support/huggingface/hub` (excluded from backup) rather than `Library/Caches`, which the system purges without notice; installs from earlier versions are moved there on first use. On macOS the runtime's own cache (`~/.cache/huggingface/hub`, or `HF_HOME` / `HF_HUB_CACHE`) is used. `TTSModelStore(cacheRoots:)` overrides both.

<!-- PREVIEWS:START -->
Hear every catalogued model before you pick one: [Docs/model-previews.md](Docs/model-previews.md) lists languages, voices, features and a short clip per voice (same sentence for all), and the [playable page](https://fil-technology.github.io/TTSMLX/) has inline players.
<!-- PREVIEWS:END -->

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
.package(url: "https://github.com/fil-technology/TTSMLX.git", from: "0.8.0")
```

Then depend on the `TTSMLX` product in your target.

### Required dependency versions (forks)

TTSMLX builds against **two forked dependencies**, pinned `exact` in
`Package.swift`. Both carry patches that are **not in any upstream tagged
release**, so resolving upstream instead of the fork either fails to compile or
silently ships without a crash fix. When you add or bump TTSMLX, let it drive
these — don't pin older versions of them yourself.

| Dependency | Required | Why the fork |
| --- | --- | --- |
| `mlx-audio-swift` | `fil-technology/mlx-audio-swift` **0.1.8-tts.4** | Upstream v0.1.8 plus `TTSModelRegistry` (queryable loader table and companion repositories, which TTSMLX calls directly) and MOSS-TTS-Nano bundled voices / codebook dial / per-chunk decoding; since `0.1.8-tts.4` also the regular-Chatterbox fixes (multilingual config detection, reference-faithful text pipeline with `[SPACE]` and language tags). |
| `mlx-swift` | `fil-technology/mlx-swift` **0.33.100** | Upstream 0.33.0 with the MLX C++ submodule repointed at `fil-technology/mlx`, which ignores the iOS background-clamp error on in-flight Metal command buffers (Metal-in-background crash fix). The `.100` patch number is reserved so the tag can never collide with an upstream release. |

**`mlx-swift` identity conflict.** Upstream `mlx-audio-swift` names
`ml-explore/mlx-swift`, so SwiftPM can resolve the shared `mlx-swift`
identity to upstream — an app **without** the Metal background patch, and the
build still succeeds. Add this to your app's `.swiftpm/configuration/mirrors.json`
(both spellings are required; some packages omit the `.git`):

```json
{
  "object": [
    { "original": "https://github.com/ml-explore/mlx-swift.git",
      "mirror": "https://github.com/fil-technology/mlx-swift.git" },
    { "original": "https://github.com/ml-explore/mlx-swift",
      "mirror": "https://github.com/fil-technology/mlx-swift.git" }
  ],
  "version": 1
}
```

`Tools/install-mirrors.sh` installs it and `Tools/verify-mlx-fork.sh` checks the
resolved submodule URL and greps the patch marker out of `device.cpp` — wire the
verify step into CI.

**Common failure: `TTSModelRegistry` is undefined.** `TTSModelRegistry` lives in
`mlx-audio-swift` (module `MLXAudioTTS`), **not** in TTSMLX's own source. A build
error that it's undefined means your resolution is compiling TTSMLX against
upstream `Blaizzy/mlx-audio-swift` or an **old fork tag** — usually a stale
`Package.resolved` that wasn't re-resolved after bumping TTSMLX. Fix it by
moving the fork up:

```bash
swift package update mlx-audio-swift     # or: rm Package.resolved && swift package resolve
```

In Xcode: **File ▸ Packages ▸ Reset Package Caches**, then **Update to Latest
Package Versions**. Confirm your `Package.resolved` then shows
`fil-technology/mlx-audio-swift` at `0.1.8-tts.4` and `mlx-swift` at
`0.33.100` from `fil-technology/mlx-swift`.

## Licences

Every catalog entry says what its weights allow, so an app never has to look it up:

```swift
entry.license.name          // "CC-BY-NC-4.0"
entry.license.tier          // .nonCommercial
entry.license.note          // who to credit, which clause bites
TTSMLX.supportedModels                         // validated, commercial use allowed
TTSMLX.models(maximumTier: .attributionRequired)  // adds CC-BY models (credit them)
TTSMLX.models(maximumTier: .nonCommercial)        // adds Voxtral and OmniVoice: personal, non-monetised use only
```

Non-commercial means exactly that: a monetised, sponsored or product-promoting video is commercial use. Research-only weights (Higgs Audio v3) never get a descriptor because their licence forbids publishing the output.

## Voices, features and controls

Every descriptor answers the same questions, whichever loader is behind it:

```swift
let model = TTSMLX.modelCatalog.first { $0.id == "mlx-community/Ming-3.0-tts-0.5B-bf16" }!.descriptor!

model.sortedFeatures            // [.streaming, .builtInVoices, .voiceCloning, .multilingual, .eventTags, .instruction, .emotion, .speed, .voiceDesign]
model.capabilities.sampleRate   // 44_100
model.supportedEventTags        // [.laugh, .sigh, .cough, .breath, .hesitation]
for voice in model.suggestedVoices {
    voice.name       // "George"
    voice.language   // .english
    voice.gender     // .male
    voice.summary    // "British. Audiobooks and formal announcements"
}
```

The options are uniform too. Set what you want; the synthesizer translates it into the loaded model's own knobs (Ming's structured instruction, Qwen3 CustomVoice's `"speaker, instruction"` voice string, Chatterbox's exaggeration scalar, Kokoro's rate factor) and reports anything the model cannot honour through `TTSDiagnostic.controlsIgnored` rather than failing:

```swift
let text = "That's the news. \(TTSEventTag.laugh) Back to you."   // "[laugh]" → "[Laughter]" on Ming, "<laugh>" on Orpheus, dropped elsewhere
let options = TTSSynthesisOptions(
    voice: "UK_George",
    instruction: nil,            // free-form delivery, e.g. "warm, unhurried storytelling voice"
    emotion: .happy,             // TTSEmotion
    speed: .slow                 // TTSSpeed
)
let audio = try await synthesizer.synthesize(text, using: model, options: options)
```

`model.features.contains(.emotion)` tells you up front whether a knob will be used. `Docs/model-previews.md` lists the features, voices and languages of every entry with a clip per voice.

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

## Natural prosody (0.9.0)

Three things decide whether a voice reads "robotic" before the model is even
involved, and the framework now gets all three right by default:

- **Punctuation reaches the model.** `TTSTextChunker` keeps the terminal
  `.` `!` `?` `…` `,` `;` `:` on every chunk (it used to cut just before it),
  so questions rise, sentences fall and commas breathe. Marks inside numbers,
  times and URLs (`3.14`, `10:30`, `1,000`, `www.x.com`) are not boundaries.
- **The model's own sampling settings are respected.** `TTSGenerationProfile`
  no longer overrides temperature / top-p; every model ships values its
  authors tuned (Orpheus and VyvoTTS at 0.6 / 0.8 with a repetition penalty).
  `.highQuality` only guarantees a token budget of at least 2048, and the
  profile still drives MOSS-TTS-Nano's codebook count. Explicit
  `TTSSynthesisOptions.temperature` / `topP` are still honoured.
- **Chunks are joined like speech, not spliced.** Each chunk gets an 8 ms
  raised-cosine fade at both edges (no clicks at seams) and is followed by a
  pause sized to the break it ended on: 250 ms after a sentence, 450 ms after a
  paragraph, 120 ms after a clause. Pauses are yielded as their own
  `TTSAudioBufferChunk` with `isPadding == true`, written into narration
  bundles and played back, but excluded from word-timing math.

```swift
// Defaults: .natural. Tune or disable per request.
var options = TTSSynthesisOptions()
options.chunkJoin = TTSChunkJoin(sentencePause: 0.35, paragraphPause: 0.6)
options.chunkJoin = .none   // pre-0.9 behaviour: raw buffers, no pause
```

Every `TTSChunkInfo` now carries a `boundary` (`.paragraph`, `.sentence`,
`.clause`, `.open`) you can use for your own pacing. Existing narration
bundles keep playing; regenerate them to pick up the new chunk texts and
pauses (cache keys include the chunk text, so they miss once).

What is *not* fixed by this: 4-bit model variants flatten timbre (prefer the
8-bit / bf16 entries where the device allows), and 80–100M models stay small.

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
