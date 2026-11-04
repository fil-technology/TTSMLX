# Changelog

All notable changes to this project will be documented in this file.

The format follows Keep a Changelog and the project uses Semantic Versioning.

## [Unreleased]

## [0.13.0] - 2026-11-04

### Added
- Licence tiers. Every catalog entry (and its descriptor) carries a
  `TTSModelLicense` with a `TTSModelUsageTier`: commercial (MIT, Apache-2.0),
  attribution required (CC-BY: Pocket-TTS), non-commercial (CC-BY-NC and
  -SA), research only (Higgs v3) or unknown (VyvoTTS publishes none).
  `TTSMLX.supportedModels` stays commercial-only; `TTSMLX.models(maximumTier:)`
  is the explicit opt-in for the rest. The previews table shows the licence.
- `mlx-community/Voxtral-4B-TTS-2603-mlx-4bit` (Mistral, CC-BY-NC-4.0) is
  validated on macOS and has a descriptor: 9 languages, 20 preset voices tied
  to their language, incremental output. About 0.8x realtime warm, first
  streamed chunk in 2.8-3.7 s, MLX peak 3.1-3.4 GB with the cache capped.
- `mlx-community/OmniVoice` (k2-fsa, CC-BY-NC weights) is validated on macOS
  and has a descriptor: voice design from a description (through
  `TTSSynthesisOptions.voice` or `instruction`) and cloning from a clip plus
  its transcript. About 1x realtime warm, all audio at the end (non-autoregressive), MLX
  peak 5.0-5.7 GB in fp32, so the entry is gated to Macs.

## [0.12.0] - 2026-11-04

### Changed
- `mlx-community/MOSS-TTS-Nano-100M` is `.validated` (so it joins
  `TTSMLX.supportedModels`) after an on-device run: iPhone 17, five passages
  through the Reader path, first audio 2.4-3.1 s warm, 1.3x realtime, MLX peak
  1.0-1.2 GB, no end-of-audio miss in 42 chunks. `peakMemoryMB` is now 1300.
  Closes URGENT item 3.

### Added
- `TTSRuntimeMemory` (peak, active and cache bytes of the MLX runtime, with
  `resetPeak()`), so apps can show or log runtime memory without importing MLX.
- Validation harness: `Tests/MossDeviceValidationTests.swift` (enable with
  `MOSS_DEVICE=1`, runs on the host under `xcodebuild`) and the demo app's
  `--moss-validation` launch argument, which runs the same measurement on a
  device and prints `[moss-device]` lines to the console.

## [0.11.1] - 2026-11-04

### Fixed
- Downloaded models no longer live where iOS can delete them. On iOS-family
  systems the store's first cache root is now
  `Library/Application Support/huggingface/hub` (marked excluded from backup)
  instead of the runtime's `Library/Caches` default, which the system purges
  under storage pressure without notice. Downloads, background downloads and
  the runtime loader all use that root; installs already sitting in
  `Library/Caches` are moved there on the store's first lookup. macOS is
  unchanged and `HF_HOME` / `HF_HUB_CACHE` still win. Closes URGENT item 4.

## [0.11.0] - 2026-11-04

### Added
- `mlx-community/Ming-3.0-tts-0.5B-bf16` (Ant Group Ming-3.0-TTS, #14 on the
  tts-bench board) is a catalog entry with a descriptor: 7 languages, built-in
  English voices (`UK_George`, `US_Emma`, `UK_Charlotte`) and Chinese voices,
  reference-clip cloning, 44.1 kHz output. Validated end to end on macOS.
  Numbers (macOS, debug build): 8-10 s of audio in 25-50 s warm, generation
  is per ~24-word fragment with no audio before a fragment completes, MLX
  peak 4.2 GB (active 2.85 GB), buffer cache up to 2 GB unless capped.
  The mlx-community checkpoint bundles its CAM++ speaker encoder, so the
  background downloader no longer pre-fetches the 780 MB
  `mlx-community/Step-Audio-2-token2wav` companion the runtime lists for the
  Ming loader.
- Three Ming preview clips on the previews page and table.
- One control surface for every model. `TTSSynthesisOptions` gains
  `instruction` (free-form delivery), `emotion` (`TTSEmotion`) and `speed`
  (`TTSSpeed`); the synthesizer translates them per loader (Ming's structured
  instruction, Qwen3 CustomVoice's "speaker, instruction" voice string,
  Chatterbox's exaggeration scalar, Kokoro's rate factor) and reports the ones
  a model cannot honour through `TTSDiagnostic.controlsIgnored` instead of
  failing. `TTSEventTag` gives non-verbal sounds one canonical spelling
  (`[laugh]`, `[sigh]`, ...) that is rewritten into each model's own
  (`<laugh>` for Orpheus, `[Laughter]` for Ming, `[laugh]` for Chatterbox
  Turbo) and dropped for models without tags, so the same text can be sent
  anywhere without a tag being read aloud.
- `TTSModelCapabilities.features` (`TTSModelFeature`: streaming, built-in
  voices, voice cloning, multilingual, event tags, instruction, emotion, speed,
  voice design), `.eventTags` (the model's spellings) and `.sampleRate`, plus
  `TTSModelDescriptor.features` / `sortedFeatures` / `supportedEventTags`, so
  an app can show what a model does without reading `runtimeNotes`.
- `TTSVoice` carries `displayName`, `language`, `gender` and `summary`
  (equality and cache keys still use the identifier). Catalog voices are
  annotated: Kokoro's 54 decoded from the `<lang><gender>_` prefix, the Qwen3
  CustomVoice speakers, Orpheus, MeloTTS accents, MOSS and Ming.
- The audio cache key includes the controls, so the same text with another
  emotion is not served from cache.

### Fixed
- Reference clips are now resampled to the loaded model's sample rate before
  they reach the runtime. Runtime models take a bare sample array and assume
  their own rate (Chatterbox 24 kHz, Ming 44.1 kHz, MOSS 48 kHz), so a clip at
  any other rate was cloned with shifted pitch and tempo. The 48 kHz clip used
  for the 0.10.1/0.10.2 Chatterbox runs was affected.

### Changed
- The model previews page is now published with GitHub Pages at
  https://fil-technology.github.io/TTSMLX/ (`.github/workflows/pages.yml`
  deploys `Docs/previews` on every push to `main` that touches that folder).
  README and `Docs/model-previews.md` link there instead of htmlpreview.

## [0.10.3] - 2026-11-04

### Fixed
- Kokoro with a non-English `TTSSynthesisOptions.language` threw
  `LexiconError.unsupportedLanguage("french")`: the runtime keys its lexicons
  by ISO code (`fr`, `ja`, `cmn`, `en-us`) while `TTSLanguage` identifiers are
  names. `TTSSpeechSynthesizer` now maps names to Kokoro's codes for that
  loader only (other loaders, such as Qwen3-TTS, keep the name); an unknown
  name becomes nil so Kokoro infers the language from the voice prefix.

### Added
- Model previews: `Docs/model-previews.md` (per model: status, languages,
  voices, features, catalog peak memory, and one MP3 clip per voice, all
  saying the same sentence) and `Docs/previews/index.html`, a page with
  inline players. Clips live under `Docs/previews/audio` and were generated
  on an Apple-silicon Mac with `Tools/previews` (a temporary executable
  target; see the header comment) and rendered with
  `Tools/render-previews.py`. README links both.

## [0.10.2] - 2026-11-04

### Changed
- `mlx-audio-swift` pin: `fil-technology/mlx-audio-swift` **`0.1.8-tts.4`**.
  Two Chatterbox fixes for the regular (Llama) model, both absent upstream:
  - `ChatterboxConfiguration` now decodes the mlx-community multilingual
    checkpoints (`chatterbox-{fp16,8bit,4bit}`: `"multilingual": true` /
    `"vocab_size": 2454`, no `t3` block) with the multilingual T3 preset
    instead of the English-only one.
  - `tokenizeText` mirrors the reference `EnTokenizer`/`MTLTokenizer`
    pipeline: `punc_norm`, lowercase + NFKD for the multilingual vocabulary,
    `[SPACE]` word boundaries, and a leading `[xx]` tag derived from the
    `language` argument (ISO code or TTSMLX language name). Upstream dropped
    every space (the `Whitespace` pre-tokenizer discards them) and ignored the
    language. Turbo is untouched.

### Added
- Catalog: `mlx-community/chatterbox-4bit` (Resemble AI Chatterbox, #2 on the
  tts-bench board; multilingual weights, 23 languages) as an `.implemented`
  entry with a descriptor: voice `default` from `conds.safetensors`,
  reference-audio cloning, `TTSSynthesisOptions.language` selects the language
  tag. Validated end to end on macOS in English, French and German with the
  default voice and in English with a 48 kHz reference clip. Replaces the
  discovery-only `chatterbox-fp16` row.

### Notes
- Chinese, Japanese, Hebrew, Korean and Russian do not get the reference's
  script-specific rewrites (Cangjie, kana normalisation, niqqud, Korean
  normalisation, stress marks); expect lower quality in those five.
- Memory on macOS: MLX peak active 2.5 GB (3.0 GB with a reference clip);
  the MLX buffer cache grew to 14 GB over one run without a cap, 3.3 GB
  process footprint with `MLX.Memory.cacheLimit` at 512 MB. Same advice as
  for Chatterbox Turbo: cap the cache or call `releaseRuntimeBuffers()`.
- Speed in a debug build with the cap: T3 about 40 tokens/s (25 tokens per
  second of audio), S3Gen about 2.5 s per chunk, whole-chunk generation.

## [0.10.1] - 2026-11-04

### Added
- Catalog: `mlx-community/chatterbox-turbo-4bit` (Resemble AI Chatterbox
  Turbo, #3 on the tts-bench board) as an `.implemented` entry with a
  descriptor. Validated end to end on macOS on the 0.1.8-tts.3 runtime with
  the bundled default voice (`conds.safetensors`, voice `default`) and with a
  48 kHz reference clip through `TTSSynthesisOptions.referenceAudio`; inline
  event tags (`[laugh]`, `[chuckle]`, `[sigh]`, ...) render. The background
  downloader plans the 417 MB checkpoint plus the 495 MB
  `mlx-community/S3TokenizerV2` companion. Replaces the discovery-only
  `chatterbox-turbo-fp16` row (3 GB; never run here).
- `TTSModelStore.searchModels` now keeps `chatterbox` repos among the
  runtime-supported results.

### Notes
- Chatterbox Turbo is slow in a debug build: the T3 stage runs about
  12 tokens/s (25 tokens per second of audio) and upstream generates each
  chunk whole, so the first audio of a chunk arrives after roughly twice the
  chunk's duration (22 s for a 10 s sentence pair). The catalog entry says so;
  measure a release build before using it for live narration.
- Memory: MLX peak active memory was 2.5 GB on macOS for a two-sentence
  chunk (descriptor `peakMemoryMB: 2_500`, `minimumDeviceClass: .iPhone`, in
  line with the Qwen3-TTS 0.6B entry). The MLX buffer cache grew to 7 GB
  (8.5 GB process footprint) with no cap; a 512 MB cap held the footprint at
  3.2 GB. Pocket-TTS and Soprano under the same runner stay near 1 GB. Apps
  should cap the MLX cache or call `releaseRuntimeBuffers()` between
  utterances with this model. On-device measurement is still pending, as for
  every other `.implemented` entry.
- Chatterbox (regular, `chatterbox-fp16`, 2.6 GB) stays discovery-only.

## [0.10.0] - 2026-11-04

Runtime migration: TTSMLX now runs on upstream `Blaizzy/mlx-audio-swift` v0.1.8
(38 TTS families) through a thin fork, on `mlx-swift` 0.33. Public TTSMLX API
is unchanged; the dependency stack consumers resolve is not.

### Changed
- `mlx-audio-swift` pin: `fil-technology/mlx-audio-swift` **`0.1.8-tts.3`**, a
  new branch cut from upstream v0.1.8. The old v0.1.3-based lineage ends at
  `0.1.7-tts.2`. The fork now only adds `TTSModelRegistry` (queryable loader
  table + companion repositories), the `gradium_phonon_tts` model-type alias,
  and MOSS-TTS-Nano bundled voices / codebook dial / per-chunk decoding.
- `mlx-swift` pin: `fil-technology/mlx-swift` **`0.33.100`** = upstream 0.33.0
  with the `mlx` submodule at `fil-technology/mlx` `v0.33.0-tts-bg-safe.1`.
  The background-safe Metal patch is re-targeted at the command-buffer
  completion handler in `device.cpp` (where upstream now records errors). The
  tag is a normal version with a reserved patch number, so it satisfies every
  `>= 0.33.0` range and can never collide with an upstream release (closes the
  URGENT.md re-tag follow-up). `Tools/verify-mlx-fork.sh` checks `device.cpp`.
- `mlx-swift-lm` is no longer a dependency: `GenerateParameters` comes from
  `MLXAudioCore`. `swift-huggingface` moves to 0.12.0. Consumers that pinned
  `mlx-swift-lm` for TTSMLX's sake can drop it; apps that use it for their own
  LLMs need a 3.x release built on `mlx-swift` 0.33.
- Requires the Swift 6.3 toolchain (Xcode 26.3+) because `mlx-swift` 0.33 does;
  CI moved to the `macos-26` runner.
- MOSS-TTS-Nano runs on upstream's port: `referenceAudio` cloning now works
  (upstream ships the codec encoder) and `supportsReferenceAudio` is `true`;
  the bundled voices gain `en_news` as the default. See URGENT.md item 3 for
  what still keeps it `.implemented`.
- Model search surfaces Kokoro and MeloTTS results alongside the existing
  families.

### Added
- Catalog entries with descriptors (`.implemented`, synthesized end to end on
  macOS): **Kokoro 82M** (`mlx-community/Kokoro-82M-bf16`, 54 voices, 8
  languages, #1 on the tts-bench board), **Phonon 31M** (`gradium/phonon-31m-en`)
  and **MeloTTS English** (`mlx-community/MeloTTS-English-MLX`, 5 accents).
- Discovery-only catalog entries (routable by the runtime, not yet validated
  here, reasons in `runtimeNotes`): Chatterbox, Chatterbox Turbo, Higgs Audio
  v3, OmniVoice, Voxtral 4B, LongCat-AudioDiT 1B, Ming-3.0-TTS 0.5B, Maya1,
  Sesame CSM-1B, OuteTTS 1.0 1B, VibeVoice Realtime, Audio8, VoxCPM2, Dia.
- `Patches/mlx-c-0.33.0-background-safe-command-buffer.patch`;
  `Docs/mlx-swift-bg-safe-fork.md` rewritten for the 0.33 forks.

### Notes
- Kitten TTS stays discovery-only: the runtime's loader needs
  `voices.safetensors`, and the mlx-community checkpoint ships `voices.npz`.
- Upstream's Qwen3-TTS 72-frame speech-decoder sliding window and the Voxtral
  streaming fix landed on upstream `main` after v0.1.8; they come with the
  next fork bump.

### Validation
Re-validated end to end on the new runtime on macOS: Pocket-TTS, Soprano 80M,
Marvis 250M, MOSS-TTS-Nano (bundled voice and reference audio), plus the three
new entries. Unit suite: 227 tests, 33 suites.


## [0.9.1] - 2026-11-03

### Added

- **Soprano 1.1** (`mlx-community/Soprano-1.1-80M-bf16`) catalog entry — the
  current Soprano release (#7 on the public tts-bench leaderboard). Same
  architecture as the validated Soprano-80M; loads and synthesizes end to end.
- **Qwen3-TTS 0.6B CustomVoice** (`mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-4bit`)
  catalog entry, and **named speakers for both CustomVoice builds**: pass
  `"ryan"`, `"serena"`, `"vivian"`, `"aiden"`, `"ono_anna"`, `"sohee"`,
  `"uncle_fu"`, `"eric"` or `"dylan"` as the voice, optionally followed by a
  style instruction (`"serena, whisper softly"`). `suggestedVoices` lists them.
- `Docs/model-support.md` now records the status of every leaderboard model.

### Fixed

- **Qwen3-TTS CustomVoice models failed to load** (`DecodingError.typeMismatch`
  on `talker_config.spk_id`), including the 1.7B CustomVoice entry already in
  the catalog, and the speaker table was never used, so every speaker sounded
  the same. Fixed in the runtime fork (`mlx-audio-swift` **0.1.7-tts.2**,
  ported from upstream v0.1.8): flexible config decoding plus speaker-token
  injection into the codec prefix. Consumers must resolve the new fork tag.


## [0.9.0] - 2026-11-03

### Changed — voices sound less robotic

Three framework-level causes of flat, "robotic" output, found while auditing
why most voices sounded worse than the same models do upstream. None of them
needs a new model; all three are on by default and the API is additive.

- **The chunker now keeps terminal punctuation.** `TTSTextChunker` cut every
  chunk just *before* its `.` `!` `?` `,` `;` `:`, so the model never saw the
  mark that carries intonation and pauses ("How are you" instead of "How are
  you?"). Every chunk now ends with its punctuation run (closing quotes and
  brackets included), newlines still break but are never part of a chunk, and
  a mark only counts as a boundary when whitespace or the end of text
  follows, so `3.14`, `10:30`, `1,000`, `e.g.` and URLs are no longer split.
  Punctuation-only segments are dropped instead of being sent to the model.
  `chunks(for:)` now returns exactly what `chunkInfos(for:)` would (packed
  short sentences included), so cache keys agree across both APIs.
  *Migration:* chunk texts change, so content-addressed caches and
  narration bundles regenerate once; existing bundles keep playing.
- **`TTSGenerationProfile` no longer overrides temperature / top-p.** The
  profiles replaced each model's tuned sampling (Orpheus / VyvoTTS 0.6 / 0.8
  + repetition penalty) with 0.75–1.0 / 0.85–0.98 — `.highQuality` being the
  hottest and least stable — which produced pitch wobble, slurred words and
  the occasional garbage syllable. Profiles now leave sampling to the model;
  `.highQuality` guarantees a token budget of at least 2048 (long chunks are
  never truncated) and the MOSS-TTS-Nano codebook dial is unchanged.
  Explicit `TTSSynthesisOptions.temperature` / `topP` still override.
- **Chunks are joined naturally.** New `TTSSynthesisOptions.chunkJoin`
  (`TTSChunkJoin`, default `.natural`): an 8 ms raised-cosine fade at both
  edges of every chunk removes clicks at seams, and a pause follows each
  chunk sized to its boundary (250 ms sentence, 450 ms paragraph, 120 ms
  clause, none mid-phrase). The fade holds back only 8 ms of audio, so
  time-to-first-buffer is unchanged. Pauses are yielded as
  `TTSAudioBufferChunk` with the new `isPadding` flag, persisted into
  narration bundles and played back, and excluded from word-timing math
  (`chunkFinished` durations still include them so playback timelines stay
  correct). `.none` restores raw buffers.

### Added

- `TTSChunkBoundary` (`.paragraph` / `.sentence` / `.clause` / `.open`) with
  `infer(from:)`; `TTSChunkInfo.boundary`; `TTSChunkJoin`;
  `TTSAudioBufferChunk.isPadding`. 12 new tests (chunker punctuation,
  boundary kinds, edge shaper, pause table, profile behaviour).


## [0.8.2] - 2026-11-03

### Fixed

- **`installedModels()` listed ordinary language models as installed TTS
  models** (regression in 0.8.1). The 0.8.1 listing fix accepted any model
  the runtime registry could map, but that mapping is for *loading* — it
  turns `llama` into Orpheus and `qwen3` into Qwen3-TTS, which are also the
  model types of plain Llama / Qwen3 LLMs — so an LLM that mlx-lm left in the
  shared hub cache showed up as a voice and failed at load. A registry match
  now counts only alongside a TTS-specific signal: the repo is in TTSMLX's
  catalog, or its files sit in the TTS runtime's own `mlx-audio/` download
  layout. Soprano, VyvoTTS and Qwen3-TTS downloaded by TTSMLX stay listed.

## [0.8.1] - 2026-11-03

### Fixed

- **Model downloads were broken for every catalog model** (reported from a
  consuming app as Soprano "404 for README.md", VyvoTTS "fails with an empty
  error", and Qwen3 "downloads 1.9 GB, then reports not installed"). Three
  distinct bugs in the download path:
  - **Direct (`modelURL` + `files`) downloads requested the bare
    `<repo>/<file>` path on Hugging Face**, which is the HTML site and answers
    404 for every file — `README.md` was just the first HEAD to fail. Soprano
    (both variants) and pocket-tts use this path. Files are now fetched from
    `resolve/main/<file>`; static mirrors keep plain path appending.
  - **A finished download could be reported as "not installed".** The hub
    download and the MLX loader used the runtime's default cache
    (`HubCache.default`, which honours `HF_HOME` / `HF_HUB_CACHE`) while
    `isInstalled` / `installedModels()` searched the store's `cacheRoots` — so
    a custom root, or that environment, split them. `TTSModelStore` now
    routes download, load and lookup through one cache rooted at its first
    cache root (new `modelCacheDirectory`), the default roots lead with the
    runtime's cache directory, and `ensureDownloaded` trusts the directory it
    just populated rather than re-deriving it.
  - **`TTSBackgroundModelDownloader` skipped every nested file**, so
    Qwen3-TTS's `speech_tokenizer/` and pocket-tts's `embeddings/` never
    arrived and the "complete" download could not load. Nested paths are now
    selected (hidden components and traversal still refused), matching the
    runtime's own snapshot globs.
- **`installedModels()` dropped freshly downloaded models.** It listed a model
  only when the catalog's *validated* list contained it or its `config.json`
  literally mentioned "tts" — so Soprano (`model_type: soprano`), VyvoTTS
  (`qwen3`) and Orpheus (`llama`), all `.implemented` rather than validated,
  vanished from the list the moment they finished downloading, and an app
  driving its UI from that list showed them as not installed. Any model the
  runtime registry can load is now listed.
- **Load failures no longer surface with an empty message.** `ensureDownloaded`
  wraps loader errors as `TTSError.modelLoadFailed`, and `TTSError` falls back
  to the error's structural description (then its type) when the underlying
  `localizedDescription` is blank — some MLX/runtime failures are.

### Added

- **Sentence-granular streaming (`TTSStreamGranularity`).** `streamAndCacheNarration`
  (and `speakStreaming`) take a `granularity:`: `.buffer` (previous behaviour —
  every ~¼ s buffer is yielded as generated), `.chunk` (each text chunk is
  yielded as one buffer once fully generated), or `.chunkAfterFirst` (fast
  first chunk, whole chunks after). When generation cannot keep up with
  playback, whole-chunk yields mean audio can only pause *between* sentence
  groups instead of dying mid-word. `speakStreaming` defaults to
  `.chunkAfterFirst`; `streamAndCacheNarration` keeps `.buffer` for
  compatibility. Cached chunks were always replayed whole.


### Fixed

- **Word highlight froze after the first generated sub-chunk.**
  `streamAndCacheNarration` generated each text chunk through the public
  `synthesizeStream`, which emits `.streamingFinished` per call. The playback
  controller's stream word observer treats that event as end-of-narration, so
  after the first *generated* chunk it flushed every known word on the next
  transient queue drain and stopped following playback; `isDurationFinal` also
  flipped true far too early. Sub-chunk generation now runs without the
  terminal diagnostic and `streamAndCacheNarration` emits exactly one
  `.streamingFinished` (narrated duration, chunk count) when every chunk is
  done. Fully-cached replays now emit it too, so consumers get one consistent
  end-of-stream signal regardless of cache state.
- **Concurrent generations on one model could race.** Only `speakStreaming`
  guarded against overlap (by cancelling in-flight work); any other pair of
  callers — a prefetch queue draining while the user tapped Play, or a bake
  running alongside a live stream — could run two generations against the
  same cached model instance and corrupt its KV cache ("RoPE cache length
  exceeded", garbled audio). Every MLX generation now takes a per-synthesizer
  FIFO gate (`TTSGenerationGate`): overlapping requests queue instead of
  racing, and a queued request that gets cancelled leaves the queue with
  `CancellationError`.
- **Cached chunk replay decoded audio on the main thread.** The
  `streamAndCacheNarration` drain Task is MainActor-bound (MLX streaming
  requires it), so replaying a cached chunk decoded the whole AAC/WAV file on
  the main thread — a visible UI stall at every cached chunk boundary. Replay
  decoding now runs on a detached task.
- **`TTSPlaybackController` was unrecoverable after an audio-session
  interruption.** A phone call or Siri stops the `AVAudioEngine` underneath the
  controller; `pause()` then no-op'd (the node was no longer "playing"), so
  `state` stayed `.playing` and `resume()` refused to run — or, if the state
  was right, `playerNode.play()` on the stopped engine raised an ObjC
  exception and crashed the app. `pause()` now records `.paused` whenever the
  controller was playing, and `resume()` / `schedule()` restart the engine
  before touching the player node. New `isEngineRunning` exposes the engine
  state for hosts that handle `AVAudioSession.interruptionNotification`.
- **Resigning active aborted the process where MLX has no Metal backend.**
  The background handler unconditionally called `Stream.gpu.synchronize()`,
  which *creates* the Metal device on first touch; in the iOS Simulator that
  aborts, so an app that had never synthesized anything crashed the first time
  another app came to the front. The drain now only runs once MLX has actually
  been initialized by a model load.


## [0.8.0] - 2026-09-01

### Added

- **Model-cache management API for long-lived synthesizers.** The synthesizer
  already keeps a loaded model resident across calls (`prepareModel` caches by
  `descriptor.id`), so a consumer that holds **one** `TTSSpeechSynthesizer`
  across requests skips the ~2 s weight reload on every call after the first.
  This release adds the surface to drive that deliberately:
  - `preload(_:hfToken:progressHandler:)` — warm a model ahead of first use
    (thin wrapper over `warmUp` that doesn't return the "did work" Bool).
  - `unloadCachedModels()` — drop all resident models and return their MLX
    weights/buffers (alias of `unloadAll()`), for memory-pressure / shutdown.
  - `init(modelStore:diagnosticHandler:maxResidentModels:)` — bound how many
    distinct models stay resident.
  - **Single-flight load dedup:** two concurrent first-use calls for the same
    model now share one load instead of racing two.

### Changed

- **Default model residency is now capped at 1 (LRU).** Loading a second
  distinct model on the same synthesizer evicts the least-recently-used one
  (emitting `modelUnloaded` and returning its buffers) to bound unified memory.
  This matches real single-model-at-a-time TTS usage; raise the cap via the new
  `maxResidentModels` init parameter to keep several models hot. No effect on
  the common path (repeated calls with one model, or voice/language switches on
  one model — those keep the existing cache-hit / variant-reload behavior).

## [0.7.0] - 2026-08-30

### Fixed

- **`onPlaybackEnd` fired prematurely mid-stream** whenever the audio queue
  drained between chunks, so streamed playback looked "finished" repeatedly.
  In a reader UI this flipped state back to stopped mid-read — word highlighting
  vanished and the Play button reappeared while audio was still coming.
  `TTSPlaybackController` now tracks whether the stream is still producing and
  only finishes once it has genuinely ended.
- **Choppy / stop-start streamed reading on prose.** `TTSTextChunker` emitted
  one chunk per sentence/clause and never packed short segments together, so a
  page of short sentences became dozens of tiny chunks (e.g. 808 chars → 22
  chunks). Each tiny chunk paid full per-chunk generation overhead and let the
  audio queue drain between chunks → audible stop-start. The chunker now packs
  consecutive segments up to `followupChunkCharacterLimit` (the first chunk
  stays small for fast time-to-first-audio), cutting that example to ~5 chunks.
- **Crash on restarting playback while a prior stream was still generating**
  (`RoPE cache length exceeded` in CSM/Marvis). With look-ahead, a previous
  `speakStreaming` could still be generating chunks in the background when a new
  one started, running two generations against the same cached (non-thread-safe)
  model instance and corrupting its KV cache. `speakStreaming` now cancels any
  in-flight generation before starting (serial model use).

- **Marvis and Orpheus failed to load** with a misleading "Network unavailable:
  Key …CSMllama3ScaledRoPE" (really a model-load error). Their `ScaledRoPE`
  precomputes `cos`/`sin` caches that MLX reflects as parameters with no
  matching checkpoint keys, so `verify: .all` (`.allModelKeysSet`) rejected the
  load. Fixed in the backend by relaxing to `[.noUnusedKeys, .shapeMismatch]`;
  `mlx-audio-swift` pin bumped `0.1.3-tts.1` → `0.1.4-tts.1`.

### Added

- **Compressed narration audio (`TTSAudioCodec`).** Narration bundles can now
  store chunk audio as **AAC-LC** (`.m4a`, ~24–48 kbps mono → **~8–16× smaller**
  than 24 kHz/16-bit WAV) or **Apple Lossless** (~2×), instead of only WAV.
  Opt in per synthesis via `TTSSynthesisOptions.audioCodec` (defaults to `.wav`,
  so existing behavior is unchanged); it flows through `streamAndCacheNarration`
  and `prepareNarration`. Playback is untouched — `AVAudioFile` decodes every
  codec transparently — and word-timing/karaoke stays aligned because timings
  come from the manifest (measured from the PCM frame count *before* encoding),
  never from file size or sample count. The manifest gains an additive, optional
  `codec` field and records each chunk's real extension, so old WAV bundles keep
  playing, a bundle may even **mix codecs** (resume across a codec switch), and
  the change does not bump the manifest `schemaVersion`. `TTSAudioCache` now
  recognizes `.m4a`/`.aac` entries alongside `.wav`/`.caf`.
- **Migration API to recompress already-generated audio.**
  `TTSPreparedNarration.recompress(bundleAt:to:)` transcodes a bundle in place
  (all voice/language sub-bundles, or a legacy root bundle), rewriting the
  manifest and deleting the superseded files — MLX-free and idempotent, so a
  host can reclaim space on the *current* library, not just future books.
  `TTSAudioCache.recompressAllBundles(to:progress:)` sweeps the whole managed
  store and reports before/after byte totals plus `(done, total)` progress.
- **Realtime conversational TTS loop (`TTSRealtimeSession`).** A low-latency
  controller for the "ask → speak → repeat" flow: feed it text turns (from any
  speech-to-text source) and it speaks them with **barge-in** — a new
  `.interrupt` turn instantly stops both in-flight generation
  (`cancelAllInFlight`) and audio (`playback.stop()`), then starts the new turn;
  `.enqueue` speaks turns back-to-back. Emits `TTSRealtimeEvent`
  (turnStarted / firstAudio / turnFinished / interrupted / failed / idle) and a
  per-turn `onWord` for karaoke. A generation token keeps a superseded turn from
  advancing the queue. Speech-to-text is intentionally external (the
  `mlx-audio-swift` backend has Voxtral streaming STT + SmartTurn turn detection
  for a future fully on-device mic→text→speech loop).
- **Demo app: a "Live" tab** exercising the realtime loop — type turns (a
  stand-in for STT), watch them speak with karaoke highlighting and per-turn
  status, toggle barge-in, Stop/Clear, and see time-to-first-word.
- **Bounded look-ahead for live streaming playback (constant-memory book
  reading).** `speakStreaming` now caps how far audio generation runs ahead of
  playback via a new `lookAheadSeconds:` parameter (defaults to a device-aware
  window from `TTSDeviceProfile.recommendedLookAheadSeconds` — 12 s on
  tight-memory iPhones up to 45 s on Mac). Generation suspends once that much
  audio is queued ahead of the playback head and resumes as it drains, so
  reading a whole book streams in roughly constant memory (a few seconds of
  PCM) instead of piling the entire book's audio into the `AVAudioEngine`
  queue — and it cuts battery/thermal load. Pass `lookAheadSeconds: 0` to
  restore the previous unbounded behavior. Backgrounding never deadlocks the
  producer (task cancellation and `stop()` both release parked generation).
- `TTSPlaybackBackpressure` — the look-ahead credit primitive (reserve/release
  in seconds of audio), plus a `backpressure:` parameter on
  `streamAndCacheNarration` and `TTSPlaybackController.play(stream:…)` so custom
  pipelines can opt into the same bound.
- `TTSDeviceProfile.recommendedLookAheadSeconds`, scaled by device memory.
- **Demo app: a "Reader" tab** for reviewing long-text behavior — drop a `.txt`
  or paste a long passage, pick any runnable model (validated or implemented),
  stream it with karaoke word-by-word highlighting and auto-scroll, and watch a
  live readout of time-to-first-word and resident memory plus an adjustable
  look-ahead window. Exercises `speakStreaming(lookAheadSeconds:)` end to end.
- **Expanded multilingual catalog.** Added selectable catalog entries that
  route to already-shipped backend loaders (verified via each repo's
  `config.json` `model_type`):
    - `mlx-community/Qwen3-TTS-12Hz-0.6B-Base-4bit` — smaller 4-bit multilingual.
    - `mlx-community/Qwen3-TTS-12Hz-1.7B-Base-4bit` — higher-quality multilingual.
    - `mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-4bit` — multilingual with
      reference-audio / voice-design conditioning.
    - `mlx-community/Soprano-80M-4bit` — tiny (~60 MB) fast English model.
  These are staged `.implemented` (not `.validated`): they carry full
  descriptors and synthesize end to end, but are excluded from
  `supportedModels` / `recommendedModel` until run + memory-profiled on a
  physical iPhone. `peakMemoryMB` on them are conservative estimates. All
  Qwen3-TTS entries now share `TTSMLX.qwen3TTSLanguages` (15 languages).

## [0.6.1] - 2026-06-16

### Fixed

- **Made v0.6.x safely consumable end-to-end.** v0.6.0's crash fixes
  depended on patched dependencies applied only on the maintainer's
  machine (local-path `mlx-audio-swift`, `swift package edit` on
  `mlx-swift`), so downstream consumers pulling v0.6.0 still hit the
  original crashes. v0.6.1 pins every dependency to public tagged forks
  that carry the patches, with **no source changes in TTSMLX itself**
  (only `Package.swift` / `Package.resolved`):
    - `mlx-audio-swift` → `github.com/fil-technology/mlx-audio-swift`
      `@ 0.1.3-tts.1` — Mimi/PocketTTS KV-cache reset (the
      `broadcast_shapes` crash on model-instance reuse).
    - `mlx-swift` → `github.com/fil-technology/mlx-swift @ 0.31.5` —
      upstream 0.31.3 with its `mlx` C++ submodule repointed at
      `github.com/fil-technology/mlx @ v0.31.3-tts-bg-safe.1`, which
      swallows the iOS background-permission Metal error in
      `check_error`. Tagged `0.31.5` (a normal version above upstream's
      0.31.4) so it satisfies `mlx-swift-lm`'s `0.31.3..<0.32.0` range;
      it is functionally 0.31.3 + the submodule patch.
  See `Docs/mlx-swift-bg-safe-fork.md`. Verified: `swift build` + full
  test suite (100 tests / 14 suites) green against the pinned forks.

- **Metal-in-background crash** definitively. The Swift defenses we
  shipped in 0.6.0 (synchronous shutdown flag, GPU stream synchronize
  on `willResignActive`, drain-task cancellation) prevent new MLX
  submissions after backgrounding but cannot prevent Metal from firing
  completion handlers on buffers that were already submitted. Those
  handlers run on Metal's callback thread and throw `std::runtime_error`
  from `mlx::core::gpu::check_error` when the buffer reports
  `Insufficient Permission (to submit GPU work from background)` —
  unreachable by Swift try-catch, so the process dies. The fix is a
  C++ patch to `mlx-swift`'s submodule `mlx` (file
  `Source/Cmlx/mlx/mlx/backend/metal/eval.cpp`): `check_error` now
  swallows the specific background-permission error and returns
  cleanly. All other Metal errors still throw as before. Patch saved
  at `Patches/mlx-c-0.31.3-background-safe-check_error.patch`; fork
  steps in `Docs/mlx-swift-bg-safe-fork.md`.

### Added

- `startCharacterOffset: Int = 0` parameter on both
  `streamAndCacheNarration` overloads and on `speakStreaming`. When
  non-zero, the drain loop skips every chunk whose
  `characterRange.upperBound <= startCharacterOffset` before any I/O or
  event emission — no `chunkStarted` / `chunkFinished` / `chunkTimings`
  fire for skipped chunks. The first chunk that straddles or exceeds
  the offset is yielded normally for both REPLAY and GENERATION paths.
  Cached chunks before the offset stay on disk untouched and remain
  valid for a future call at offset 0. Audio still starts at the
  beginning of the first yielded chunk (no sub-chunk seek API exists
  yet), so a saved within-chunk pause position replays a short prefix
  of that chunk before live sync catches up — but resume granularity
  is now sub-chunk (~5–20 s window) rather than full-chunk (potentially
  minutes).

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
