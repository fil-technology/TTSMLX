# Platform compatibility

Which catalog model runs where, and where that has actually been checked.
`Tests/TTSCompatibilityDocTests.swift` fails if a descriptor-bearing catalog
entry is missing from this table or its gate column disagrees with the
catalog, so the table cannot drift from the code silently.

How the columns are decided:

- **Gate** is the catalog's `minimumDeviceClass` plus `peakMemoryMB`. The
  synthesizer refuses a model on a device below the class or with less
  physical memory than the peak (`TTSError.deviceUnsupported`); apps can
  override through `TTSSynthesisOptions`. *iPhone* means every iPhone with
  enough memory, *iPad* means iPad and Mac, *Mac* means Mac only.
- **Stage** is the catalog stage: `.validated` entries are in
  `TTSMLX.supportedModels` and eligible for `recommendedModel(for:)`;
  `.implemented` entries carry a full descriptor and synthesize, but an app
  has to pick them explicitly.
- **Measured on Mac / iPhone** says where this repository has run the model
  through the benchmark harness or a validation pass, with a pointer to the
  numbers. "–" means not run there; a model gated to iPhone that has only
  been measured on a Mac is expected to run on a phone, not proven to.

The Mac is a MacBook Pro 14-inch 2021 (M1 Pro, 32 GB); the phone is an
iPhone 17 (8 GB) on iOS 27.2. Numbers: `Docs/benchmarks.md`.

| Model (catalog id) | Stage | Gate | Peak MB (catalog) | Measured on Mac | Measured on iPhone | Licence tier |
|---|---|---|---|---|---|---|
| `Marvis-AI/marvis-tts-250m-v0.2-MLX-8bit` | validated | iPhone | 400 | yes (end to end, re-validated on the 0.1.8 runtime in 0.10.0) | – | commercial |
| `mlx-community/pocket-tts` | validated | iPhone | 900 | yes, benchmarks.md | yes, benchmarks.md (and shipped on iPhone in ReadMeBook since 0.3) | attribution required (two presets non-commercial) |
| `mlx-community/Soprano-80M-bf16` | validated | iPhone | 220 | yes (end to end, re-validated in 0.10.0) | – | commercial |
| `mlx-community/VyvoTTS-EN-Beta-4bit` | validated | iPhone | 500 | yes (end to end, 0.3) | – | unknown |
| `mlx-community/orpheus-3b-0.1-ft-bf16` | validated | Mac | 6000 | yes (end to end, 0.3) | – (gated) | commercial |
| `mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit` | validated | iPhone | 4200 | yes, benchmarks.md | **killed by iOS** on the iPhone 17 at paragraph length (MLX peak 3.6 GB on a sentence, 0.6x realtime); not a phone model at 8-bit | commercial |
| `mlx-community/Qwen3-TTS-12Hz-0.6B-Base-4bit` | implemented | iPhone | 3400 | yes, benchmarks.md | **killed by iOS** on the iPhone 17 on the second sentence trial (MLX peak 3.4 GB, 0.8x realtime) | commercial |
| `mlx-community/Qwen3-TTS-12Hz-1.7B-Base-4bit` | implemented | iPhone | 2800 | – | – | commercial |
| `mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-4bit` | implemented | iPhone | 2800 | – | – | commercial |
| `mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-4bit` | implemented | iPhone | 1200 | yes (0.11.0, end to end) | – | commercial |
| `mlx-community/Soprano-80M-4bit` | implemented | iPhone | 150 | yes (0.14.0 toolkit smoke) | – | commercial |
| `mlx-community/Soprano-1.1-80M-bf16` | implemented | iPhone | 220 | yes (0.9.1, end to end) | – | commercial |
| `mlx-community/Kokoro-82M-bf16` | implemented | iPhone | 2000 | yes, benchmarks.md | yes, benchmarks.md | commercial |
| `gradium/phonon-31m-en` | implemented | iPhone | 300 | yes (0.10.x, end to end) | – | commercial |
| `mlx-community/MeloTTS-English-MLX` | implemented | iPhone | 1000 | yes (0.10.x, end to end) | – | commercial |
| `mlx-community/MOSS-TTS-Nano-100M` | validated | iPhone | 1900 | yes, benchmarks.md | yes, benchmarks.md (0.16.1 bounds; before them a runaway take peaked at 3 GB and iOS killed the app) | commercial |
| `mlx-community/chatterbox-turbo-4bit` | implemented | iPhone | 2500 | yes, benchmarks.md | yes, benchmarks.md | commercial |
| `mlx-community/chatterbox-4bit` | implemented | iPhone | 3000 | yes (0.10.2, end to end) | – | commercial |
| `mlx-community/Ming-3.0-tts-0.5B-bf16` | implemented | iPhone | 4500 | yes (0.11.0 validation) | – | commercial |
| `mlx-community/OmniVoice` | implemented | Mac | 6000 | yes (0.13.0 validation) | – (gated) | non-commercial |
| `mlx-community/Voxtral-4B-TTS-2603-mlx-4bit` | implemented | iPhone | 4000 | yes (0.13.0 validation) | – | non-commercial |
| `mlx-community/VibeVoice-Realtime-0.5B-8bit` | implemented | iPhone | 2000 | yes, benchmarks.md | yes, benchmarks.md | commercial |
| `mlx-community/VoxCPM2-4bit` | implemented | Mac | 6500 | yes, benchmarks.md | – (gated) | commercial |
| `mlx-community/VoxCPM1.5-4bit` | implemented | Mac | 7500 | yes, benchmarks.md | – (gated) | commercial |

Discovery-only entries (`Kitten TTS`, `Higgs TTS 3`, `LongCat AudioDiT`,
`Maya1`, `CSM 1B`, `OuteTTS`, `Audio8`, `Dia 1.6B`) have no descriptor and
cannot be selected; `Docs/model-support.md` says why for each.

## Platform notes

- **iOS background:** Metal compute is refused while an app is in the
  background on every model; pre-bake with `prepareNarration` for
  background playback (README, "Background playback continuity").
- **iOS model storage:** downloads go to `Library/Application Support`
  (excluded from backup), never the purgeable `Caches` directory, since
  0.11.1.
- **Memory on a phone:** the harness caps the MLX buffer cache at 512 MB;
  an app should do the same (`TTSSpeechSynthesizer(runtimeCacheLimitMB:)`),
  otherwise the resident footprint keeps the generation peak instead of
  settling near the weight size.
- **Mac-only gates** (`Orpheus`, `OmniVoice`, `VoxCPM2`) come from measured
  or estimated peaks above what iOS grants a foreground app; they are not
  Metal or API limits, so a smaller quantisation could lift them.
- **What an iPhone 17 (8 GB) tolerates, measured:** Kokoro at an MLX peak of
  2.3 GB ran for minutes; Qwen3-TTS 0.6B at 3.4–3.6 GB (both 8-bit and
  4-bit, the transient is the codec decode, not the LM) was killed by iOS
  within a few trials with no scene change logged. Treat an MLX peak above
  roughly 3 GB as not shippable on 8 GB phones until the runtime decodes the
  codec in chunks.
